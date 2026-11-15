---
engagement: "{{engagement_id}}"
updated: "{{last_updated}}"
source: discovery
tags: [reachability-matrix, "engagement/{{engagement_id}}", "phase/discovery"]
---

# Reachability Matrix: {{engagement_id}}

## Overview

Tracks which hosts can reach which from each foothold or pivot point.
Updated as new footholds are established and pivots confirmed.

**Last updated**: {{last_updated}}
**Footholds**: {{foothold_count}}
**Total reachable targets**: {{reachable_count}}

## Footholds

<!-- List all current footholds / pivot points with agent status. -->

| Foothold | IP | Agent ID | Agent Status | Networks Reachable | Established |
|----------|-----|----------|--------------|--------------------|----|
<!-- {{foothold_rows}} -->

## Reachability Table

<!-- Core matrix: source foothold → destination host → port/protocol → status.
     Status values:
       confirmed  — traffic reached destination and got response
       filtered   — no response, likely firewall drop
       refused    — RST / ICMP unreachable (port closed but host reachable)
       untested   — not yet probed
       proxied    — reachable via SOCKS proxy from another foothold
     Method: how reachability was tested (ping, tcp-connect, nmap, curl, ssh, proxy).
     Update rows as new paths are discovered or pivots established.
-->

| Source | Destination | Dest IP | Port | Protocol | Status | Method | Tested Date | Notes |
|--------|-------------|---------|------|----------|--------|--------|-------------|-------|
<!-- {{reachability_rows}} -->

## SOCKS Proxies

<!-- Active SOCKS proxies enabling multi-hop routing from Kali.
     Chain: the proxy chain path (e.g., kali → foothold1 → foothold2 → target).
-->

| Proxy Port | Foothold | Upstream | Chain | Status | Established |
|------------|----------|----------|-------|--------|-------------|
<!-- {{proxy_rows}} -->

## Network Segments

<!-- Summary view: which segments are reachable from which footholds.
     Derived from reachability table rows. -->

| Segment | CIDR | Reachable From | Confirmed Hosts | Untested Hosts |
|---------|------|----------------|-----------------|----------------|
<!-- {{segment_rows}} -->

## Pivot Plan

<!-- Planned lateral movement paths based on reachability + credential availability.
     Priority: ordered by target value and path reliability. -->

| Priority | Path | Credentials Available | Technique | Status |
|----------|------|-----------------------|-----------|--------|
<!-- {{pivot_plan_rows}} -->

## Change Log

<!-- Append a row each time this matrix is updated. -->

| Date | Change | Source |
|------|--------|--------|
<!-- {{changelog_rows}} -->

## Related Pages

- Engagement: [[{{engagement_id}}]]
- Zone sweeps: <!-- link to per-segment zone-sweep pages -->
