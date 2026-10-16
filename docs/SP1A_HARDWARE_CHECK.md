# SP1a hardware check — signals, stated minimum, and model recommendation

Run the hardware check on a host **before** you set it up as the hub. It tells
you three things:

1. What the host has: GPU, Vulkan/RADV, Mesa, usable GPU memory, system memory,
   and whether the GPU driver is ready.
2. Whether the host meets the **stated minimum** (`pass` or `below floor`).
3. On a pass, which orchestrator and classifier models to download for this host.

```bash
bash scripts/hub/hw-check.sh            # on the host, not in a container
```

The check is `scripts/hub/hw-check.sh`. Detection lives in `scripts/lib/hw.sh`
(`hw_` functions). The stated minimum and the recommendation table live in one
versioned file, `scripts/hub/hw-floor.json`.

> **Provisional.** The figures in `hw-floor.json` are not yet measured. They
> come from the published reference figures in the SP1a PRD addendum (A2, A4)
> and simple arithmetic on them. The Story 1.5 bake-off replaces each one with a
> measured value and cites its record (PRD OQ-4). Until then, every run prints
> `  !!  the stated minimum and recommendation table are provisional`.

## Signals

One line per signal, each with a status marker:

| Marker | Meaning |
|---|---|
| `  OK  ` | Read, and meets the stated minimum. |
| ` FAIL ` | Read, and does not meet it. |
| `  !!  ` | Could not be read. The line says why. |

| Signal | Source |
|---|---|
| GPU | The DRM card in sysfs (`/sys/class/drm/cardN/device`), an AMD card first. The name comes from the RADV device in `vulkaninfo`. Only the PCI vendor and device ids are printed, never a serial or UUID. |
| Vulkan/RADV | `vulkaninfo --summary`: a device with driver `DRIVER_ID_MESA_RADV`. A CPU-only device (llvmpipe) or AMDVLK does not count. |
| Mesa | The Mesa version in that RADV device's `driverInfo`. |
| Usable GPU memory | The GTT limit: `ttm.pages_limit` (`/sys/module/ttm/parameters/pages_limit`) times the page size. `amdgpu.gttsize` is deprecated and not read. |
| System memory | `MemTotal` in `/proc/meminfo`. |
| Driver readiness | The `amdgpu` kernel driver is bound to the card, the card has a render node, and you can read and write it (`/dev/dri/renderD*`; usually membership of the `render` group). |

A missing tool or an unreadable source never passes. For example, without
`vulkaninfo` the Vulkan line is `  !!  ` with "vulkaninfo not installed", the
Mesa line is `  !!  `, and the result is `below floor` with those reasons named.
Install `vulkan-tools` and run the check again.

Memory figures are decimal GB, the unit the reference figures use.

## Stated minimum

From `scripts/hub/hw-floor.json`, version 1:

| Threshold | Value | Source |
|---|---|---|
| Vulkan/RADV available | required | provisional: PRD addendum A2 (the fleet runs llama.cpp on Vulkan/RADV) |
| Mesa | ≥ 25.3 | provisional: PRD addendum A2 and the architecture stack table |
| Usable GPU memory (GTT) | ≥ 40 GB | provisional: PRD addendum A4 (orchestrator plus a second model on one GPU is about 40 GB) |
| System memory | ≥ 48 GB | provisional: 40 GB × 96/80. The A2 reference host keeps 16 of 96 GB RAM outside GTT. |

Every threshold and every model row in the file names its source in one of two
ways:

- `"record": "sha256:<64 hex>"`: the digest of the bake-off record it came from.
- `"record": null, "provisional": true, "basis": "<where the figure came from>"`.

The check refuses (exit 4) a table where any threshold or row does neither. The
table holds no host-identifying detail: no hostname, serial, account, or
topology. Only figures, model names, and quantisations.

## Recommendation table

| Role | Model | Quant | Needs (usable GPU memory) | Source |
|---|---|---|---|---|
| orchestrator | Qwen3-30B-A3B | Q4_K_M | 40 GB | provisional: A4, 17.4–18.7 GB weights within the 40 GB two-model figure |
| orchestrator | Qwen3-30B-A3B | Q5_K_M | 43.3 GB | provisional: A4, the 40 GB figure with Q4_K_M weights (18.7 GB) replaced by Q5_K_M (about 22 GB) |
| classifier | 4B-class, chosen by the bake-off | Q4_K_M | 40 GB | provisional: A4, part of the 40 GB two-model figure; its own size is measured on the hub (A5) |

"Needs" is the usable GPU memory a host must have for that row to be
recommended, with the rest of the fleet loaded beside it. For each role the
check recommends the largest row that fits. It never recommends a row whose
need exceeds the host's usable GPU memory, even when the host passes the floor.
It names each row it skipped and why.

Memory classes name the result:

| Class | Usable GPU memory |
|---|---|
| minimum | ≥ 40 GB |
| reference | ≥ 64 GB (the low end of the A2 reference host's 64–80 GB GTT) |

## Below floor

When any threshold fails or any value is unknown, the result is
` FAIL result: below floor`, with every reason listed. The check then states:

> The local classifier cannot run on this host, so gated Lane 2 sessions are
> available only as declared floor-only sessions (`lane2 up --floor-only`).
> No model download is recommended for this host.

A floor-only session runs the term-list floor without the classifier. Every
push and mount scan then needs your approval (FR-53). Nothing switches to that
mode by itself. You declare it each time.

## Result and setup next steps

The check writes its report to `$XDG_STATE_HOME/lane2/hw-check.txt` (default
`~/.local/state/lane2/hw-check.txt`). The directory is mode 0700 and the file is
mode 0600. A symlinked location is refused. `scripts/setup-day0.sh` prints this
file in its next steps when run on the host. If the file is missing, it prints
how to produce it.

The result never reaches a container, and nothing here tracks it in the
repository:

- The check refuses to run in a container (` FAIL run on the host`, exit 4,
  no values reported).
- Inside a container the next steps print nothing about the hardware check.
- No container mounts the operator's state directory.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | pass |
| 2 | usage error |
| 3 | below floor, including any value that could not be read |
| ≥ 4 | fault: run in a container, table missing, malformed, or uncited, or result not saved |

Callers treat anything but 0 as "below floor".

## Updating the table after the bake-off

When the Story 1.5 bake-off records exist:

1. Replace each `value` and `need_gpu_mem_gb` with the measured figure.
2. Set `record` to the bake-off record's digest (`sha256:...`). Set
   `provisional` to `false` and remove `basis`, or keep it as a note.
3. Set `status` to `measured` once nothing is provisional.
4. Update the tables on this page in the same PR.

## Limits

- Tuned for AMD GPUs with unified memory (integrated GPUs), where GTT is the
  usable GPU memory. Dedicated VRAM on a discrete card is not counted yet.
- The amdgpu driver's own GTT size (`mem_info_gtt_total`) is not checked. The
  check trusts `ttm.pages_limit`.
- Memory bandwidth class (PRD addendum A2) is not reported yet. Its effect on
  speed is part of the bake-off.
- The container check uses the same markers as `scripts/hub/eval-set.sh`
  (`/.dockerenv`, `/run/.containerenv`, container environment variables, the
  cgroup of PID 1). A container that hides all of them could run the check, but
  it would then read the container's own view of the hardware.

## Tests

`scripts/tests/test-hw-check.sh` (tier `ci`) builds synthetic fixture hosts
(sysfs, procfs, and device trees, with `vulkaninfo` and `getconf` stubs) and
covers:

- a passing host, and one above the floor but below a model's need;
- below floor on memory, no Vulkan, a `vulkaninfo` error, old Mesa, unknown or
  zero GTT, a missing `vulkaninfo`, unreadable sysfs, and driver-not-ready cases;
- the container refusal;
- every exit code, and the table citation rule;
- the next-steps hand-off;
- that no fixture or table file holds a hostname or account.
