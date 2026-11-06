#!/usr/bin/env bash
# Wrapper: run hashcat on Kali spoke via SSH.
# Set HASHCAT_PATH to this script so hashcat-mcp calls land on Kali.
# File paths passed to hashcat must be Kali-local paths.
exec ssh kali hashcat "$@"
