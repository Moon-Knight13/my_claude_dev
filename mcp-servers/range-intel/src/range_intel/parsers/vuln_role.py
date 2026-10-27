"""Ansible vuln role defaults parser."""

from __future__ import annotations

import logging

import yaml

logger = logging.getLogger(__name__)


def parse_vuln_defaults(content: str) -> dict:
    """Parse a vuln role's defaults/main.yml into a parameter dict."""
    try:
        data = yaml.safe_load(content)
        if isinstance(data, dict):
            return data
        return {}
    except yaml.YAMLError:
        logger.debug("Failed to parse vuln defaults YAML")
        return {}
