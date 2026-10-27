"""Merge logic: Providentia hosts + GitLab README vuln profiles."""

from __future__ import annotations

import logging

from range_intel.clients.gitlab import GitLabClient
from range_intel.models import Host, HostInstance, ImplementedVuln, MergedTarget, VMProfile
from range_intel.parsers.readme import parse_readme
from range_intel.parsers.vuln_role import parse_vuln_defaults

logger = logging.getLogger(__name__)


class ReadmeIndex:
    """Index of VM READMEs keyed by directory and boxName."""

    def __init__(self) -> None:
        self._by_dir: dict[str, VMProfile] = {}
        self._by_boxname: dict[str, VMProfile] = {}

    def add(self, profile: VMProfile) -> None:
        self._by_dir[profile.directory.lower()] = profile
        if profile.box_name:
            self._by_boxname[profile.box_name.lower().replace("-", "")] = profile

    def match(self, spec_name: str, tags: list[str] | None = None) -> tuple[VMProfile | None, str | None]:
        """Cascading match: exact dir → normalized boxName → tag correlation."""
        key = spec_name.lower()
        if key in self._by_dir:
            return self._by_dir[key], "exact"

        normalized = key.replace("-", "")
        if normalized in self._by_boxname:
            return self._by_boxname[normalized], "boxname"

        if tags:
            tag_domains = set()
            for t in tags:
                if t.startswith("actor_"):
                    tag_domains.add(t.replace("actor_", ""))
            for profile in self._by_dir.values():
                if tag_domains & set(d.lower() for d in profile.domains):
                    if spec_name.lower() in profile.directory.lower() or profile.directory.lower() in spec_name.lower():
                        return profile, "tag_correlation"

        return None, None

    @property
    def profiles(self) -> list[VMProfile]:
        return list(self._by_dir.values())


async def build_readme_index(
    gitlab: GitLabClient, vm_path: str
) -> ReadmeIndex:
    """Fetch all VM READMEs and build the index."""
    index = ReadmeIndex()
    try:
        dirs = await gitlab.list_vm_directories(vm_path)
    except Exception:
        logger.error("Failed to list VM directories from GitLab")
        return index

    for vm_dir in dirs:
        try:
            content = await gitlab.read_readme(vm_path, vm_dir)
            if content is None:
                continue
            profile = parse_readme(content, vm_dir)
            if profile:
                index.add(profile)
        except Exception:
            logger.debug("Failed to fetch/parse README for %s", vm_dir, exc_info=True)

    logger.info("README index built: %d profiles", len(index.profiles))
    return index


async def enrich_vulns(
    profile: VMProfile, gitlab: GitLabClient, vuln_path: str
) -> list[ImplementedVuln]:
    """Enrich implemented vulns with parameters from role defaults."""
    enriched = []
    for vuln in profile.implemented_vulns:
        role_name = vuln.name.rsplit("/", 1)[-1] if "/" in vuln.name else vuln.name
        platform_guess = _guess_platform(vuln.name, profile.platform)
        if platform_guess:
            defaults_content = await gitlab.read_vuln_defaults(
                vuln_path, platform_guess, role_name
            )
            if defaults_content:
                params = parse_vuln_defaults(defaults_content)
                vuln = vuln.model_copy(update={"parameters": params})
        enriched.append(vuln)
    return enriched


def _guess_platform(vuln_name: str, profile_platform: str | list[str] | None) -> str | None:
    if "linux/" in vuln_name or "vulns/linux" in vuln_name:
        return "linux"
    if "windows/" in vuln_name or "vulns/windows" in vuln_name:
        return "windows"
    if isinstance(profile_platform, str):
        return profile_platform
    if isinstance(profile_platform, list) and profile_platform:
        return profile_platform[0]
    return None


def merge_target(
    host: Host,
    team_nr: int | None,
    profile: VMProfile | None,
    match_method: str | None,
) -> MergedTarget:
    """Merge a Providentia host with its README profile."""
    instance: HostInstance | None = None
    if team_nr is not None:
        for inst in host.instances:
            if inst.team_nr == team_nr:
                instance = inst
                break

    vulns = profile.implemented_vulns if profile else []
    mitre = profile.mitre_attack_ids if profile else []
    platform = profile.platform if profile else None

    return MergedTarget(
        host_id=host.id,
        spec_name=host.spec_name,
        role=host.role,
        platform=platform,
        tags=host.tags,
        instance=instance,
        vulns=vulns,
        mitre_attack_ids=mitre,
        match_method=match_method,
        vm_profile=profile,
    )
