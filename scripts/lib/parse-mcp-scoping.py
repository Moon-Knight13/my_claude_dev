#!/usr/bin/env python3
"""Parse mcp-secrets.yaml and return scoped secret lists for an MCP server.

Usage: parse-mcp-scoping.py <config_file> <mcp_name>
Output: comma-separated secrets | comma-separated allowed vars
        e.g. "TUONI_USERNAME,TUONI_PASSWORD|TUONI_USERNAME,TUONI_PASSWORD"

Exits non-zero on any error so the caller can detect failure.
"""
import re
import sys


def parse(config_file: str, mcp_name: str) -> str:
    with open(config_file) as f:
        content = f.read()

    secrets: list[str] = []
    mcp_allowed: list[str] = []
    in_secrets = False
    in_scoping = False
    in_mcp = False

    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue

        if line.startswith("secrets:"):
            in_secrets = True
            in_scoping = False
            in_mcp = False
            continue
        elif line.startswith("scoping:"):
            in_scoping = True
            in_secrets = False
            in_mcp = False
            continue
        elif not line.startswith(" ") and not line.startswith("\t"):
            in_secrets = False
            in_scoping = False
            in_mcp = False
            continue

        if in_secrets and stripped.startswith("- "):
            secrets.append(stripped[2:].strip().strip('"').strip("'"))

        if in_scoping:
            m = re.match(r"^  (\S+):\s*(.*)", line)
            if m:
                key = m.group(1)
                val = m.group(2).strip()
                if key == mcp_name:
                    in_mcp = True
                    if val == "[]":
                        in_mcp = False
                    continue
                else:
                    in_mcp = False
                    continue
            if in_mcp and stripped.startswith("- "):
                mcp_allowed.append(stripped[2:].strip().strip('"').strip("'"))

    return ",".join(secrets) + "|" + ",".join(mcp_allowed)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <config_file> <mcp_name>", file=sys.stderr)
        sys.exit(1)
    print(parse(sys.argv[1], sys.argv[2]))
