# RDP Fronting Feasibility — Guacamole Gateway

Status: **PROVEN** (2026-11-18)

## Summary

T3 preview tools can interact with Windows RDP sessions through an Apache
Guacamole web gateway. This gives the agent framework Windows desktop access
despite T3 device tools supporting only iOS and Android natively.

## Architecture

```
T3 Thread
  → preview_open(guacamole-url)
    → SSH tunnel
      → Kali spoke (Guacamole Docker Compose)
        → guacd → RDP to Windows target
```

Guacamole runs on the Kali spoke as a Docker Compose stack. The hub reaches it
through the existing SSH proxy chain, with a local port forward to the
Guacamole web UI.

## What works

| Capability | Method | Notes |
|---|---|---|
| Authentication | `preview_act` type into form fields | Standard web form login |
| Connection selection | `preview_act` click | Guacamole connection list |
| Keyboard input | `preview_act` key-by-key | Through Guacamole HTML5 canvas |
| Visual feedback | `preview_snapshot` | PNG screenshots, readable by agent |
| Connection management | Guacamole REST API | Create/delete RDP connections programmatically |

## Limitations

- **No native T3 device support for Windows.** iOS/Android only. This is a
  workaround, not a first-class integration.
- **Guacamole gateway required.** Additional infrastructure on the Kali spoke.
- **SSH tunnel required.** Hub cannot reach Kali spoke directly; port forward
  needed.
- **Key-by-key input only.** No bulk paste into the Guacamole canvas. Typing
  long strings is slow.
- **Canvas is opaque.** No accessibility tree — the agent reads screen state via
  screenshots only. OCR-level understanding, not DOM inspection.
- **Operator keyboard passthrough broken.** T3 preview keyboard passthrough does
  not work on canvas-based applications. Operator cannot type into the RDP
  session through the preview pane.

## Production prerequisites

1. **PR #364 merged** — Guacamole Ansible role for Kali bootstrap.
2. **Docker group membership** — the service account on Kali needs `docker`
   group to run Compose without sudo.
3. **RDP connections via REST API** — connections created programmatically, not
   through the admin UI.
4. **Change default admin password** — `guacadmin/guacadmin` default is not
   acceptable.
5. **Persistent SSH tunnel** — consider `autossh` for the port forward so it
   survives disconnects.

## Integration path

Once PR #364 lands and prerequisites are met:

1. Guacamole deploys as part of Kali spoke bootstrap.
2. RDP connections created via REST API during engagement setup (recon phase
   output feeds connection parameters).
3. T3 threads use `preview_open` to interact with Windows targets.
4. Screenshots provide visual confirmation of actions.

## Related

- PR #364 — Guacamole Ansible role
- `docs/PROJECT.md` — hub-and-spoke topology
