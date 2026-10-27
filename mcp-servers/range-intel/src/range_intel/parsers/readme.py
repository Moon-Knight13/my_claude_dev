"""README frontmatter + body parser."""

from __future__ import annotations

import logging
import re

import yaml

from range_intel.models import ImplementedVuln, VMProfile

logger = logging.getLogger(__name__)

_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n(.*)", re.DOTALL)
_VULN_SECTION_RE = re.compile(
    r"#\s*Implemented Vulnerabilities\n(.*?)(?=\n#|\Z)", re.DOTALL
)
_COMMENT_STRIP_RE = re.compile(r"\s*#.*$")


def _infer_category(name: str) -> str | None:
    """Infer vuln category from role name prefix."""
    prefixes = [
        "initial_access",
        "privesc",
        "persist",
        "rce",
        "disable",
        "anon",
        "pam",
        "web",
        "ad",
        "registry",
    ]
    clean = name.rsplit("/", 1)[-1] if "/" in name else name
    for prefix in prefixes:
        if clean.startswith(prefix):
            return prefix
    return None


def _parse_frontmatter(raw: str) -> dict | None:
    """Parse YAML frontmatter, tolerant of broken YAML."""
    try:
        cleaned_lines = []
        for line in raw.split("\n"):
            cleaned_lines.append(_COMMENT_STRIP_RE.sub("", line))
        return yaml.safe_load("\n".join(cleaned_lines))
    except yaml.YAMLError:
        logger.debug("YAML parse failed, trying line-by-line salvage")
        salvaged = {}
        for line in raw.split("\n"):
            line = _COMMENT_STRIP_RE.sub("", line).strip()
            if ":" in line and not line.startswith("-"):
                key, _, val = line.partition(":")
                key = key.strip()
                val = val.strip()
                if val.startswith("["):
                    try:
                        salvaged[key] = yaml.safe_load(val)
                    except yaml.YAMLError:
                        salvaged[key] = []
                elif val.startswith('"') or val.startswith("'"):
                    salvaged[key] = val.strip("\"'")
                elif val:
                    salvaged[key] = val
        return salvaged if salvaged else None


def _parse_vuln_section(body: str) -> list[ImplementedVuln]:
    """Extract implemented vulnerabilities from README body."""
    match = _VULN_SECTION_RE.search(body)
    if not match:
        return []

    vulns = []
    current_name: str | None = None
    current_desc: str | None = None
    current_steps: list[str] = []

    for line in match.group(1).strip().split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("**"):
            continue

        if stripped.startswith("- "):
            if current_name:
                vulns.append(
                    ImplementedVuln(
                        name=current_name,
                        category=_infer_category(current_name),
                        description=current_desc,
                        abuse_steps=current_steps,
                    )
                )
            text = stripped[2:].strip().strip("`")
            if ":" in text:
                name_part, _, desc_part = text.partition(":")
                current_name = name_part.strip().strip("`")
                current_desc = desc_part.strip()
            else:
                current_name = text
                current_desc = None
            current_steps = []
        elif stripped.startswith("- ") is False and current_name:
            indent = stripped.lstrip("- ").strip()
            if indent:
                current_steps.append(indent)

    if current_name:
        vulns.append(
            ImplementedVuln(
                name=current_name,
                category=_infer_category(current_name),
                description=current_desc,
                abuse_steps=current_steps,
            )
        )

    return vulns


def _to_list(val: str | list | None) -> list:
    if val is None:
        return []
    if isinstance(val, list):
        return [v for v in val if v]
    return [val] if val else []


def parse_readme(content: str, directory: str) -> VMProfile | None:
    """Parse a VM README into a VMProfile."""
    fm_match = _FRONTMATTER_RE.match(content)
    if not fm_match:
        logger.debug("No frontmatter in %s", directory)
        return None

    meta = _parse_frontmatter(fm_match.group(1))
    if not meta:
        logger.warning("Could not parse any frontmatter from %s", directory)
        return None

    body = fm_match.group(2)
    vulns = _parse_vuln_section(body)

    return VMProfile(
        directory=directory,
        box_name=meta.get("boxName"),
        category=meta.get("category"),
        platform=meta.get("platform"),
        domains=_to_list(meta.get("domains")),
        contains_vulns=_to_list(meta.get("containsVulns")),
        vuln_paths=_to_list(meta.get("vulnPaths")),
        mitre_attack_ids=_to_list(meta.get("mitreAttackId")),
        last_updated=str(meta["lastUpdated"]) if "lastUpdated" in meta else None,
        implemented_vulns=vulns,
        raw_body=body,
    )
