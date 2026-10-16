# Hub systemd units

`lane2 install` renders every `*.service`, `*.socket`, and `*.timer` here from the
installed commit (never from a checkout), lints it, and installs it. See
[docs/SP1A_HUB_SETUP.md](../../../docs/SP1A_HUB_SETUP.md).

Placeholders, replaced at install:

| Placeholder | Becomes |
|---|---|
| `@LANE2_CODE@` | `<prefix>/<commit>`, the installed tree |
| `@LANE2_STATE@` | the hub state root |
| `@LANE2_CONFIG@` | the hub config directory |

Every service unit must run as a non-root `User=` and carry `NoNewPrivileges=yes`,
`ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and `LimitCORE=0`.
No unit may reference a home or workspace path.

Only these may be enabled at boot (have an `[Install]` section), each service with
`Restart=on-failure`: `gate-*.socket`, `fleet-*.service`, `lane2-notify.service`.
Supervisors, Lane 2 containers, and sessions never start at boot.

Story 1.2 adds the fleet units here; Stories 2.3 and 2.4 add the gate sockets and
the notifier.
