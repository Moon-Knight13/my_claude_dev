#!/usr/bin/env python3
"""Smoke test for range-intel MCP data sources.

Reads tokens from .env (never prints them). Tests:
1. Providentia API — list environments, fetch one inventory sample
2. GitLab API — resolve project, list VM directories, fetch one README
3. README parser — parse frontmatter + vuln section from fetched README

Run:  python3 smoke_test.py
Prereq: httpx (already on deploybox40), pyyaml (stdlib-bundled). No pip install needed.
"""

import os
import re
import sys
from pathlib import Path

try:
    import httpx
except ImportError:
    sys.exit("httpx not installed — try: python3 -m venv .venv && .venv/bin/pip install httpx")

import yaml

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
SKIP = "\033[33mSKIP\033[0m"
INFO = "\033[36mINFO\033[0m"


def parse_dotenv(path: Path) -> dict[str, str]:
    """Parse .env without external dependencies."""
    vals: dict[str, str] = {}
    if not path.exists():
        return vals
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        vals[key.strip()] = value.strip().strip("'\"")
    return vals


def load_config():
    env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        sys.exit(f".env not found at {env_path} — copy .env.example and fill in tokens")
    env = parse_dotenv(env_path)
    return {
        "providentia_url": env.get("PROVIDENTIA_URL", "").rstrip("/"),
        "providentia_token": env.get("PROVIDENTIA_TOKEN", ""),
        "gitlab_url": env.get("GITLAB_URL", "").rstrip("/"),
        "gitlab_token": env.get("GITLAB_TOKEN", ""),
        "gitlab_project": env.get("GITLAB_PROJECT", ""),
        "gitlab_ref": env.get("GITLAB_REF", "main"),
        "gitlab_vm_path": env.get("GITLAB_VM_PATH", "inventories/dcm/vm"),
        "gitlab_vuln_path": env.get("GITLAB_VULN_PATH", "inventories/dcm/roles/vulns"),
    }


def test_providentia(cfg: dict) -> bool:
    if not cfg["providentia_token"]:
        print(f"  [{SKIP}] PROVIDENTIA_TOKEN not set")
        return False

    client = httpx.Client(
        base_url=cfg["providentia_url"],
        headers={"Authorization": f"Token {cfg['providentia_token']}"},
        timeout=15,
    )

    # Test 1: list environments
    print(f"  [{INFO}] GET /api/v3/")
    r = client.get("/api/v3/")
    if r.status_code != 200:
        print(f"  [{FAIL}] Status {r.status_code}: {r.text[:200]}")
        return False

    data = r.json()
    envs = data.get("result", [])
    print(f"  [{PASS}] {len(envs)} environment(s) found:")
    for env in envs:
        print(f"         - {env['id']}: {env['name']}")

    if not envs:
        print(f"  [{FAIL}] No environments — token may lack permissions")
        return False

    # Test 2: fetch hosts for first environment
    env_id = envs[0]["id"]
    print(f"\n  [{INFO}] GET /api/v3/{env_id}/hosts")
    r = client.get(f"/api/v3/{env_id}/hosts")
    if r.status_code != 200:
        print(f"  [{FAIL}] Status {r.status_code}")
        return False

    hosts = r.json().get("result", [])
    print(f"  [{PASS}] {len(hosts)} host(s) in '{env_id}':")
    for h in hosts[:10]:
        print(f"         - {h}")
    if len(hosts) > 10:
        print(f"         ... and {len(hosts) - 10} more")

    # Test 3: fetch one host detail with instances
    if hosts:
        host_id = hosts[0] if isinstance(hosts[0], str) else hosts[0].get("id", "")
        print(f"\n  [{INFO}] GET /api/v3/{env_id}/hosts/{host_id}")
        r = client.get(f"/api/v3/{env_id}/hosts/{host_id}")
        if r.status_code == 200:
            host = r.json().get("result", {})
            instances = host.get("instances", [])
            print(f"  [{PASS}] Host '{host_id}':")
            print(f"         spec_name: {host.get('spec_name')}")
            print(f"         role: {host.get('role')}")
            print(f"         tags: {host.get('tags', [])[:5]}")
            print(f"         {len(instances)} instance(s)")
            if instances:
                inst = instances[0]
                print(f"         First instance: team_nr={inst.get('team_nr')}, "
                      f"hostname={inst.get('hostname')}, "
                      f"connection_address={inst.get('connection_address')}")

    return True


def test_gitlab(cfg: dict) -> bool:
    if not cfg["gitlab_token"]:
        print(f"  [{SKIP}] GITLAB_TOKEN not set")
        return False

    client = httpx.Client(
        base_url=cfg["gitlab_url"],
        headers={"PRIVATE-TOKEN": cfg["gitlab_token"]},
        timeout=15,
    )

    # Test 1: resolve project
    encoded_project = cfg["gitlab_project"].replace("/", "%2F")
    print(f"  [{INFO}] GET /api/v4/projects/{encoded_project}")
    r = client.get(f"/api/v4/projects/{encoded_project}")
    if r.status_code != 200:
        print(f"  [{FAIL}] Status {r.status_code}: {r.text[:200]}")
        return False

    project = r.json()
    project_id = project["id"]
    print(f"  [{PASS}] Project resolved: id={project_id}, path={project['path_with_namespace']}")

    # Test 2: list VM directories
    vm_path = cfg["gitlab_vm_path"]
    print(f"\n  [{INFO}] GET /api/v4/projects/{project_id}/repository/tree?path={vm_path}")
    r = client.get(
        f"/api/v4/projects/{project_id}/repository/tree",
        params={"path": vm_path, "per_page": 100, "ref": cfg["gitlab_ref"]},
    )
    if r.status_code != 200:
        print(f"  [{FAIL}] Status {r.status_code}: {r.text[:200]}")
        return False

    entries = r.json()
    dirs = [e["name"] for e in entries if e["type"] == "tree"]
    print(f"  [{PASS}] {len(dirs)} VM directories found:")
    for d in dirs[:10]:
        print(f"         - {d}")
    if len(dirs) > 10:
        print(f"         ... and {len(dirs) - 10} more")

    # Test 3: fetch one README
    if dirs:
        test_vm = "nextcloud-dm" if "nextcloud-dm" in dirs else dirs[0]
        file_path = f"{vm_path}/{test_vm}/README.md"
        encoded_file = file_path.replace("/", "%2F")
        print(f"\n  [{INFO}] GET /api/v4/projects/{project_id}/repository/files/{encoded_file}/raw")
        r = client.get(
            f"/api/v4/projects/{project_id}/repository/files/{encoded_file}/raw",
            params={"ref": cfg["gitlab_ref"]},
        )
        if r.status_code != 200:
            print(f"  [{FAIL}] Status {r.status_code}: {r.text[:200]}")
            return False

        content = r.text
        print(f"  [{PASS}] Fetched {test_vm}/README.md ({len(content)} bytes)")

        # Test 4: parse it
        return test_readme_parse(content, test_vm)

    return True


def test_readme_parse(content: str, name: str) -> bool:
    fm_match = re.match(r"^---\n(.*?)\n---\n(.*)$", content, re.DOTALL)
    if not fm_match:
        print(f"  [{FAIL}] No frontmatter in {name}")
        return False

    try:
        meta = yaml.safe_load(fm_match.group(1))
    except yaml.YAMLError as e:
        print(f"  [{FAIL}] YAML parse error in {name}: {e}")
        box_match = re.search(r"boxName:\s*(\S+)", fm_match.group(1))
        if box_match:
            print(f"  [{INFO}] Salvaged boxName: {box_match.group(1)}")
        return False

    body = fm_match.group(2)
    vulns = []
    vuln_section = re.search(
        r"#\s*Implemented Vulnerabilities\n(.*?)(?=\n#|\Z)", body, re.DOTALL
    )
    if vuln_section:
        for line in vuln_section.group(1).strip().split("\n"):
            line = line.strip()
            if line and not line.startswith("**"):
                vulns.append(line)

    print(f"\n  [{PASS}] README parse for '{name}':")
    print(f"         boxName:  {meta.get('boxName')}")
    print(f"         platform: {meta.get('platform')}")
    print(f"         domains:  {meta.get('domains')}")
    print(f"         vulns:    {len(vulns)} implemented")
    for v in vulns[:5]:
        print(f"           {v}")
    if len(vulns) > 5:
        print(f"           ... and {len(vulns) - 5} more")

    return True


def main():
    print("=" * 60)
    print("Range-Intel MCP — Smoke Test")
    print("=" * 60)
    cfg = load_config()

    results = {}

    print("\n[1/2] Providentia API")
    print("-" * 40)
    results["providentia"] = test_providentia(cfg)

    print(f"\n[2/2] GitLab API + README Parse")
    print("-" * 40)
    results["gitlab"] = test_gitlab(cfg)

    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    for name, passed in results.items():
        status = PASS if passed else (SKIP if passed is None else FAIL)
        print(f"  {name}: {status}")

    all_pass = all(v for v in results.values())
    print(f"\n{'All data sources verified — ready to build.' if all_pass else 'Fix failures above before building.'}")
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
