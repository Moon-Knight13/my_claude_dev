# SP1a fleet — the one model-call client `fleet_call`

Every call to a local model goes through one function, `fleet_call` in
`scripts/lib/fleet.sh` (AD-10). The gate, the eval harness, and the Lane 1
client therefore call the model the same way, with the same settings. If they
did not, the eval would measure a different classifier from the one in use.

`fleet_call` also makes every call **fail closed**. If any step fails, the
caller gets a fault, and a fault means block. A fault is never retried into a
success. The input is never truncated, sampled, or split to make it fit.

Status: landed in SP1a story 1.3. The classifier uses it when
`LOCAL_MODEL_API=openai`, and the eval drafting helper always uses it. The fleet
units that serve the models (`llama-server` under systemd, pinned and
checksum-verified) are Story 1.2. Until then, point the fleet config at a
`llama-server` you started yourself.

## How a call works

```bash
source scripts/lib/fleet.sh
fleet_use_config /etc/lane2/fleet.conf      # optional; this is the default
fleet_call classifier scripts/hub/fleet/classifier.settings.json system-prompt.md < input.txt
```

The input comes on stdin. The system prompt, if any, comes as a file. Neither
is ever put on the command line of any process `fleet_call` starts. A test
checks the arguments of every process it starts.

Before any network call, `fleet_call` checks the config, the settings file,
and the input. Then it makes these requests, in this order:

| Step | Request | Passes when |
|---|---|---|
| 1 | `GET /health` | HTTP 200. A model that is still loading answers 503; that is a fault. |
| 2 | `GET /props` | It reports `n_ctx`, the context size per slot. |
| 3 | `POST /apply-template` | The server turns the messages into its prompt text. |
| 4 | `POST /tokenize` | The server counts the tokens of that prompt text. |
| — | fit check | prompt tokens + `max_tokens` ≤ `n_ctx`. |
| 5 | `POST /v1/chat/completions` | One request, with the settings file applied. |

The reply passes only if it is HTTP 200, has exactly one choice, has
`finish_reason` `stop`, and its content is not empty. If the settings ask for a
`json_schema` reply, the content must be exactly one JSON object. It must have
exactly the schema's keys, and each value must be in its enum. `fleet_call`
then prints that object on stdout. Otherwise it prints the content as it is.

## Faults

Every fault exits with a code of 4 or more, and the caller treats it as block.
Stderr gets one fixed line, never input or output text.

| Exit | Fault | Examples |
|---|---|---|
| 2 | usage | wrong number of arguments |
| 4 | config, settings, or input | endpoint missing, not loopback, or not a hub socket; no model alias; settings file missing, malformed, or setting a forbidden key; empty input; input with NUL or invalid UTF-8 |
| 5 | endpoint | `/health` not 200 (loading, error), timeout, unreachable; `/props` without `n_ctx`; `/apply-template` or `/tokenize` failed; completion timed out |
| 6 | does not fit | input over `FLEET_MAX_INPUT_BYTES`; fit check failed; server answered `exceed_context_size_error` |
| 7 | bad reply | completion not 200; malformed JSON; `finish_reason` `length` (truncated); empty; extra field; value not in the enum; more than one object |

A fault from step 1 to the fit check means no completion request is sent.

## Fleet config

The fleet config is one hub config file, `/etc/lane2/fleet.conf` by default.
It is parsed, never sourced, and the last assignment of a key wins. Only
`FLEET_` keys are read.

**Nothing comes from the environment.** That covers the config path, the
endpoint, the model, and the limits. A caller chooses another file only in
code, with `fleet_use_config`. A test sets these values in the environment and
checks that `fleet_call` ignores them.

| Key | Default | Meaning |
|---|---|---|
| `FLEET_<MEMBER>_ENDPOINT` | — (required) | `http://127.x.y.z:<port>`, `http://[::1]:<port>`, or `unix:<FLEET_SOCKET_DIR>/<name>.sock`. |
| `FLEET_<MEMBER>_MODEL` | — (required) | The exact alias the member serves (`--alias`). |
| `FLEET_SOCKET_DIR` | `/run/lane2/fleet` | The only directory a unix-socket endpoint may be in. |
| `FLEET_PROBE_TIMEOUT` | `5` | Seconds allowed for each of `/health`, `/props`, `/apply-template`, `/tokenize`. |
| `FLEET_MAX_INPUT_BYTES` | `1048576` | Largest input accepted. A bigger input is a fault. It is never cut. |
| `FLEET_MAX_RESPONSE_BYTES` | `1048576` | Largest server reply read. |
| `FLEET_CLASSIFIER_SHA256` | — | The classifier model file checksum. The parallel-verify record needs it. |
| `FLEET_STATE_DIR` | `/var/lib/lane2/fleet` | Where parallel-verify records go (mode 0700, files 0600). |

Members are lowercase names: `classifier`, `orchestrator` (Story 1.2), and
`draft` (the eval drafting model). `<MEMBER>` in a key is the uppercase name.

An endpoint must be a loopback IP address with a port, or a socket in
`FLEET_SOCKET_DIR`. Each of these is refused, with no network call:

- a missing endpoint or port (nothing relies on a default port);
- a hostname, including `localhost` (name lookup is not loopback by design);
- `https`, a user name, or a path;
- a socket outside `FLEET_SOCKET_DIR`, or a path that uses `..`.

`fleet_call` runs curl with no curlrc, no proxy, no redirects, and only the
`http` protocol.

## Settings files

A settings file fixes how one kind of call is made:

```json
{"max_tokens": 32, "timeout_seconds": 25, "params": {...}}
```

`params` are copied into the completion request. They cannot set `model`,
`messages`, `prompt`, `stream`, `n_ctx`, or any other token limit
(`max_tokens`, `n_predict`, `max_completion_tokens`). The fit check relies on
`max_tokens` being the only limit. If `response_format` is set, it must be a
`json_schema` with a flat object of string enums and `additionalProperties:
false`, so the reply can be checked exactly.

### The pinned classifier settings

`scripts/hub/fleet/classifier.settings.json` is the one settings file for every
classifier call. The classifier script uses it, and through it eval
parallel-verify does too. The gate and the eval harness will use the same file.
It sets:

| Setting | Value | Why |
|---|---|---|
| `temperature` | `0` | Same input, same verdict (NFR-3). |
| `seed` | a fixed number | The `llama-server` default (`-1`) is random. |
| `response_format` | `json_schema`, `{"verdict": "sensitive" \| "nonsensitive"}` | The model can answer only with the enum; anything else is a fault. |
| `max_tokens` | `32` | Enough for the object; counted in the fit check. |
| `cache_prompt` | `false` | Eval and production run the same way. Prompt caching can change results across batch sizes, so it stays off until the bake-off (Story 1.5) shows it gives the same verdicts. |
| `id_slot` | `-1` | Any free slot. |
| `timeout_seconds` | `25` | Upper bound on the completion step. The gate sets its own overall deadline (AD-20, Epic 2). |

To change the file, use a reviewed PR. A change to it is a change to the
classifier. The parallel-verify record and the Story 1.7 zero-diff check record
its checksum.

`scripts/hub/fleet/draft.settings.json` is the settings file for eval case
drafting (temperature 0.7, no schema).

## Transport migration (`LOCAL_MODEL_API`)

The classifier (`scripts/orchestrator/classify-sensitivity.sh`) has two
transports. `LOCAL_MODEL_API` chooses between them:

| Value | Path |
|---|---|
| `ollama` (default) | The Ollama-native `/api/generate` call, as before. Endpoint and model from `ORCH_CLASSIFIER_*`. |
| `openai` | `fleet_call classifier` with the pinned settings. Endpoint and model from the fleet config only. |
| anything else | A fault: verdict `sensitive`. |

Both fail closed to `sensitive`, as before. Both read the prompt from stdin:
a prompt passed as an argument is refused.

Before the Ollama path can be removed, both paths must give the same verdicts.
Point both at the same pinned model file on the hub, then run:

```bash
scripts/orchestrator/eval-classifier.sh --parallel-verify \
    --fleet-config /etc/lane2/fleet.conf [fixtures.jsonl ...]
```

It classifies every case under both transports. It writes a hub-only record
under `FLEET_STATE_DIR/parallel-verify/`. The record holds one row per case
(case id, both verdicts, equal or not, fault flags) and a header with the model,
prompt, settings, and fixture checksums. It never holds case text. Stdout shows
counts only.

- If no verdict differs and no call faulted, it appends a **zero-diff record**
  to `FLEET_STATE_DIR/zero-diff.jsonl` and exits 0. Story 1.7 requires this
  record.
- Otherwise it reports the differences and faults as counts, writes no
  zero-diff record, and exits 3. A fault counts against the run, never as
  "equal".

It refuses to run inside a container. This story keeps both transports, the
Ollama mock, and its CI leg. Story 1.7 removes the Ollama path after a soak.

## The lint (AD-10)

`scripts/tests/test-fleet-call.sh` fails when a tracked script outside
`scripts/lib/fleet.sh` contains a model request (`/v1/`, `/completion`,
`/api/generate`, `/api/chat`). The error names the file and line. Comment lines
and docs are not checked.

Each exemption is listed in the test by path, with the one endpoint it may use
and a reason:

| Path | May use | Reason |
|---|---|---|
| `scripts/tests/` | any | Test suites and model mocks serve or match these paths. They never call a real model. |
| `scripts/ask-local.sh`, `scripts/delegate-local.sh`, `scripts/local-health.sh` | `/api/generate` | Template routing scripts, kept until FR-39 or #89 retires them. |
| `scripts/orchestrator/classify-sensitivity.sh` | `/api/generate` | The Ollama transport, kept until Story 1.7. |
| `scripts/orchestrator/orchestrate.sh`, `sanitise.sh` | `/api/generate` | Lane 1 orchestrator callers on Ollama. They move to `fleet_call` with the Lane 1 client. |
| `scripts/orchestrator/execute-local.sh` | `/api/chat` | Same. |

The eval drafting helper (`scripts/hub/eval-set.sh draft`) is not exempt. It
calls `fleet_call draft`.

## Tests

- `scripts/tests/test-fleet-call.sh` (tier `ci`). It covers each step of the
  sequence, every fault above, endpoint policy, nothing taken from the
  environment, settings checks, determinism (same input and settings give the
  same request body), the input on no process's argv, and the lint.
- `scripts/tests/test-classifier.sh` (tier `ci`). It runs the classifier under
  the transport in `LOCAL_MODEL_API`, then runs the stdin hand-off and
  parallel-verify under both.
- `scripts/tests/mock-llama-server.py`. A Python HTTP mock of the five
  endpoints, on loopback or a unix socket. It can simulate a model that is
  loading, a prompt that is too big, a malformed or truncated reply, and a
  timeout.

CI runs every suite twice: `LOCAL_MODEL_API=ollama` and `openai`.

## What this does not cover (residuals)

- **The fit check trusts the server.** Token counts come from the server's
  own `/tokenize`. A server that miscounts could still reject the request,
  but it then answers `exceed_context_size_error`, which is also a fault.
- **Same verdicts need the same build.** Temperature 0 and a fixed seed give
  the same output on the same model file, `llama-server` build, and hardware.
  A change to any of them can change a verdict. That is why model and build
  pins (Story 1.2) and re-selection (FR-37) exist.
- **Lane 1 Ollama callers are not yet behind `fleet_call`.** The exemptions
  above call Ollama directly, with their own settings. They are not used by
  the gate.
- **The Ollama transport is outside `fleet_call`.** Until Story 1.7 removes it,
  `LOCAL_MODEL_API=ollama` makes no health or fit check. It still fails closed.
