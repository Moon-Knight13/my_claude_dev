"""MCP server entry point for range-intel."""

from __future__ import annotations

import json
import logging
import os
import sys
from typing import Any

from mcp.server import FastMCP

from range_intel.clients.gitlab import GitLabClient
from range_intel.clients.providentia import ProvidentiaClient
from range_intel.enrichment import (
    ReadmeIndex,
    build_readme_index,
    enrich_vulns,
    merge_target,
)
from range_intel.models import MergedTarget

logger = logging.getLogger("range_intel")

_prov: ProvidentiaClient | None = None
_gitlab: GitLabClient | None = None
_vm_path: str = ""
_vuln_path: str = ""
_readme_index: ReadmeIndex | None = None

mcp = FastMCP(
    "range-intel-mcp",
    instructions=(
        "Read-only intelligence server: Providentia range data + "
        "GitLab VM README vulnerability profiles. "
        "Use range_targets to get hosts for a team, range_host for detail, "
        "range_vuln_lookup to search vulns."
    ),
)


def _load_env(path: str) -> dict[str, str]:
    env: dict[str, str] = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip("\"'")
                if val:
                    env[key] = val
    except FileNotFoundError:
        pass
    return env


def _init_clients() -> None:
    global _prov, _gitlab, _vm_path, _vuln_path

    env_path = os.path.join(os.path.dirname(__file__), "..", "..", ".env")
    env_path = os.path.normpath(env_path)
    file_env = _load_env(env_path)

    alt_path = os.environ.get("RANGE_INTEL_ENV")
    if alt_path:
        file_env.update(_load_env(alt_path))

    for key, val in file_env.items():
        if key not in os.environ:
            os.environ[key] = val

    required = ["PROVIDENTIA_URL", "PROVIDENTIA_TOKEN", "GITLAB_URL", "GITLAB_TOKEN", "GITLAB_PROJECT"]
    missing = [k for k in required if not os.environ.get(k)]
    if missing:
        logger.error("Missing required config: %s", ", ".join(missing))
        sys.exit(1)

    _prov = ProvidentiaClient(
        base_url=os.environ["PROVIDENTIA_URL"],
        token=os.environ["PROVIDENTIA_TOKEN"],
    )

    _gitlab = GitLabClient(
        base_url=os.environ["GITLAB_URL"],
        token=os.environ["GITLAB_TOKEN"],
        project=os.environ["GITLAB_PROJECT"],
        ref=os.environ.get("GITLAB_REF", "main"),
    )

    _vm_path = os.environ.get("GITLAB_VM_PATH", "vm")
    _vuln_path = os.environ.get("GITLAB_VULN_PATH", "")


async def _get_index() -> ReadmeIndex:
    global _readme_index
    if _readme_index is None:
        assert _gitlab is not None
        _readme_index = await build_readme_index(_gitlab, _vm_path)
    return _readme_index


def _dump(obj: Any) -> str:
    if hasattr(obj, "model_dump"):
        return json.dumps(obj.model_dump(exclude_none=True), indent=2)
    if isinstance(obj, list):
        return json.dumps(
            [i.model_dump(exclude_none=True) if hasattr(i, "model_dump") else i for i in obj],
            indent=2,
        )
    return json.dumps(obj, indent=2, default=str)


@mcp.tool()
async def range_environments() -> str:
    """List available exercise environments from Providentia."""
    assert _prov is not None
    envs = await _prov.environments()
    return _dump(envs)


@mcp.tool()
async def range_targets(env: str, team: int, tag: str = "", role: str = "") -> str:
    """List hosts for a team in an environment, enriched with documented vulnerabilities.

    Returns merged targets with IPs, vulns, and MITRE mappings.

    Args:
        env: Environment ID (e.g. 'dcm')
        team: Team number to resolve instance IPs
        tag: Filter by tag name (optional)
        role: Filter by host role (optional)
    """
    assert _prov is not None
    hosts = await _prov.inventory(env)
    index = await _get_index()

    targets: list[MergedTarget] = []
    for host in hosts:
        if tag and tag not in host.tags:
            continue
        if role and host.role != role:
            continue

        profile, method = index.match(host.spec_name or host.id, host.tags)
        target = merge_target(host, team, profile, method)

        if target.instance is None:
            continue

        targets.append(target)

    summary = {
        "environment": env,
        "team": team,
        "total_hosts": len(targets),
        "with_vulns": sum(1 for t in targets if t.vulns),
        "targets": [
            {
                "host_id": t.host_id,
                "spec_name": t.spec_name,
                "role": t.role,
                "platform": t.platform,
                "connection_address": t.instance.connection_address if t.instance else None,
                "fqdn": t.instance.fqdn if t.instance else None,
                "vuln_count": len(t.vulns),
                "vuln_names": [v.name for v in t.vulns],
                "mitre": t.mitre_attack_ids,
                "match_method": t.match_method,
                "tags": t.tags,
            }
            for t in targets
        ],
    }
    return json.dumps(summary, indent=2)


@mcp.tool()
async def range_host(env: str, host_id: str, team: int = 0) -> str:
    """Get detailed info for one host: instances, interfaces, IPs, and enriched vulns.

    Args:
        env: Environment ID
        host_id: Host ID (spec_name) from Providentia
        team: Team number for instance resolution (0 = all instances)
    """
    assert _prov is not None and _gitlab is not None
    host = await _prov.host(env, host_id)
    index = await _get_index()
    profile, method = index.match(host.spec_name or host.id, host.tags)

    enriched_vulns = []
    if profile:
        enriched_vulns = await enrich_vulns(profile, _gitlab, _vuln_path)

    result: dict[str, Any] = {
        "host": host.model_dump(exclude_none=True),
        "match_method": method,
        "vm_profile": (
            profile.model_dump(exclude_none=True, exclude={"raw_body"})
            if profile else None
        ),
        "enriched_vulns": [v.model_dump(exclude_none=True) for v in enriched_vulns],
    }

    if team:
        for inst in host.instances:
            if inst.team_nr == team:
                result["team_instance"] = inst.model_dump(exclude_none=True)
                break

    return json.dumps(result, indent=2)


@mcp.tool()
async def range_networks(env: str) -> str:
    """List networks in an environment with address pools.

    Args:
        env: Environment ID
    """
    assert _prov is not None
    networks = await _prov.networks(env)
    return _dump(networks)


@mcp.tool()
async def range_vuln_lookup(name: str) -> str:
    """Look up a vulnerability by name across all VM profiles.

    Returns which hosts have it, exploitation steps, and parameters from role defaults.

    Args:
        name: Vulnerability or role name to search (partial match)
    """
    assert _gitlab is not None
    search = name.lower()
    index = await _get_index()

    matches = []
    for profile in index.profiles:
        for vuln in profile.implemented_vulns:
            if search in vuln.name.lower() or search in (vuln.description or "").lower():
                enriched = vuln
                if _vuln_path:
                    try:
                        enriched_list = await enrich_vulns(profile, _gitlab, _vuln_path)
                        for ev in enriched_list:
                            if ev.name == vuln.name:
                                enriched = ev
                                break
                    except Exception:
                        pass

                matches.append({
                    "host_directory": profile.directory,
                    "box_name": profile.box_name,
                    "platform": profile.platform,
                    "vuln": enriched.model_dump(exclude_none=True),
                })

    return json.dumps({"query": name, "matches": len(matches), "results": matches}, indent=2)


@mcp.tool()
async def range_tags(env: str) -> str:
    """List tags and their hierarchies in an environment.

    Args:
        env: Environment ID
    """
    assert _prov is not None
    tags = await _prov.tags(env)
    return _dump(tags)


@mcp.tool()
async def range_cache_refresh() -> str:
    """Force refresh of README index and clear API caches."""
    global _readme_index
    _readme_index = None
    if _prov:
        _prov._cache.clear()
    if _gitlab:
        _gitlab._cache.clear()
    return json.dumps({"status": "caches cleared, README index rebuilds on next query"})


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    _init_clients()
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
