# SP1a runbook

Short procedures for the hub operator. Each section grows as SP1a stories land.

## Resolve a scan-blocked workspace

`lane2 scan` printed a ref and exited 3, so the workspace cannot be mounted.

1. **See what hit**, on the hub: `sudo scripts/hub/lane2 review show gr-…`. The
   retained payload lists each hit item (`tree:<path>`, `object:<git dir>:<sha>:<type>`,
   `git:<git dir>/<file>`, `ref-names:…`) with the term's hash.
2. **If it is sensitive:** remove it from the workspace — and from git history if
   it is in an object (rewrite the history and expire the reflog and stash; a
   deleted file is still in its blob). Then `lane2 scan` again. A clean scan
   clears the state and is logged.
3. **If it is not sensitive:** `sudo scripts/hub/lane2 review exclude gr-… --path <item>`
   for each item (one item and one term per exclusion), then `lane2 scan` again.
4. **If you cannot tell:** leave it unmounted, or mark the workspace `sensitive`.

A scan that ends `unscanned` (exit ≥ 4) was a fault, not a finding: the message
says which (a symlink or git pointer outside the workspace, an import outside it,
the scan budget, or the gate). Fix that and scan again.

## Read a block

You get a desktop notification: `blocked (<category>) · ref gr-…`. Inside
Claude, the session only saw `blocked by gate · ref gr-… · see hub notification`
— never the reason.

1. **Look at it, on the hub:**

   ```bash
   sudo scripts/hub/lane2 review show gr-<the 32 hex characters>
   ```

   It prints when, which op, the origin (`operator`, `container`, or `hub`), the
   reason category, and the retained payload.

2. **Read the category:**

   | Category | Means |
   |---|---|
   | `hit:floor` | A term from your term list matched. |
   | `hit:classifier` | The local classifier judged it sensitive. |
   | `fault:*` | Nothing was judged: something failed, so the gate blocked. See the fault table in [SP1A_GATE.md](SP1A_GATE.md). |

3. **If it says `not found`:** the ref is mistyped, or it is from another hub.
   **If it says `expired`:** the payload is older than `GATE_RETAIN_DAYS` and was
   removed; the operator log line is still there.

4. **What next:** a block on your own prompt (`origin: operator`) is the gate
   doing its job — do that work locally. A hit on container-origin content
   (`origin: container`, sent as a critical notification) means sensitive
   material reached the container; Epic 4 adds the breach review and decisions.
   A `fault:*` you did not expect is a hub problem: check `lane2 check` and the
   journal for `gate-hub@*`.

Notifications missing? `systemctl --user status lane2-notify`. The gate keeps
blocking either way; the operator log has every block.
