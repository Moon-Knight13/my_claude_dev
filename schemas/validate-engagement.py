#!/usr/bin/env python3
"""Validate engagement YAML against JSON Schema with cross-reference checks.

Usage: validate-engagement.py <engagement.yaml>

Exit codes:
  0 — valid
  1 — validation errors
  2 — usage / file errors
"""
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("FATAL: PyYAML not installed — pip install pyyaml", file=sys.stderr)
    sys.exit(2)

try:
    import jsonschema
except ImportError:
    print("FATAL: jsonschema not installed — pip install jsonschema", file=sys.stderr)
    sys.exit(2)

SCHEMA_PATH = Path(__file__).parent / "engagement-schema.json"
BANNED_CRED_FIELDS = {
    "password", "hash", "secret", "ntlm", "plaintext",
    "passwd", "cleartext", "credential", "token", "private_key",
}


def load_schema():
    with open(SCHEMA_PATH) as f:
        return json.load(f)


def validate(filepath: str) -> list[str]:
    errors: list[str] = []
    path = Path(filepath)

    if not path.exists():
        return [f"file not found: {filepath}"]

    try:
        with open(path) as f:
            doc = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        return [f"invalid YAML: {exc}"]

    if doc is None:
        return ["empty or null document"]

    schema = load_schema()
    validator = jsonschema.Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.path)):
        loc = ".".join(str(p) for p in err.absolute_path) or "(root)"
        errors.append(f"{loc}: {err.message}")

    # --- Cross-reference checks beyond JSON Schema ---

    cred_ref_ids = set()
    for i, cred in enumerate(doc.get("cred_refs") or []):
        if isinstance(cred, dict):
            rid = cred.get("ref_id")
            if rid:
                cred_ref_ids.add(rid)
            for key in cred:
                if key in BANNED_CRED_FIELDS:
                    errors.append(
                        f"cred_refs[{i}]: banned field '{key}' — no plaintext secrets"
                    )

    agent_ids = set()
    payload_ids: list[str] = []
    for i, agent in enumerate(doc.get("agents") or []):
        if isinstance(agent, dict):
            aid = agent.get("agent_id")
            if aid:
                agent_ids.add(aid)
            pid = agent.get("payload_id")
            if pid:
                if pid in payload_ids:
                    errors.append(
                        f"agents[{i}]: duplicate payload_id '{pid}'"
                    )
                payload_ids.append(pid)

    # guacamole_connections cross-refs
    proxy_ids = set()
    for i, proxy in enumerate(doc.get("socks_proxies") or []):
        if isinstance(proxy, dict):
            pid = proxy.get("id")
            if pid:
                if pid in proxy_ids:
                    errors.append(f"socks_proxies[{i}]: duplicate id '{pid}'")
                proxy_ids.add(pid)
            fa = proxy.get("foothold_agent")
            if fa and agent_ids and fa not in agent_ids:
                errors.append(
                    f"socks_proxies[{i}]: foothold_agent '{fa}' not found in agents[]"
                )

    for i, conn in enumerate(doc.get("guacamole_connections") or []):
        if isinstance(conn, dict):
            cr = conn.get("cred_ref")
            if cr and cred_ref_ids and cr not in cred_ref_ids:
                errors.append(
                    f"guacamole_connections[{i}]: cred_ref '{cr}' not found in cred_refs[]"
                )
            px = conn.get("proxy")
            if px and proxy_ids and px not in proxy_ids:
                errors.append(
                    f"guacamole_connections[{i}]: proxy '{px}' not found in socks_proxies[]"
                )

    # listener id uniqueness
    listener_ids: set[str] = set()
    for i, lst in enumerate(doc.get("listeners") or []):
        if isinstance(lst, dict):
            lid = lst.get("id")
            if lid:
                if lid in listener_ids:
                    errors.append(f"listeners[{i}]: duplicate id '{lid}'")
                listener_ids.add(lid)

    # lateral_moves cred_ref validation
    for i, lm in enumerate(doc.get("lateral_moves") or []):
        if isinstance(lm, dict):
            cr = lm.get("cred_ref")
            if cr and cred_ref_ids and cr not in cred_ref_ids:
                errors.append(
                    f"lateral_moves[{i}]: cred_ref '{cr}' not found in cred_refs[]"
                )

    return errors


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <engagement.yaml>", file=sys.stderr)
        sys.exit(2)

    errors = validate(sys.argv[1])
    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        print(f"\nValidation failed: {len(errors)} error(s)")
        sys.exit(1)

    print("Validation passed")
    sys.exit(0)


if __name__ == "__main__":
    main()
