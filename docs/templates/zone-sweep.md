---
network: "{{network_cidr}}"
segment_name: "{{segment_name}}"
scan_date: "{{scan_date}}"
scan_source: "{{scan_source}}"
foothold: "{{foothold_hostname}}"
agent_id: "{{agent_id}}"
engagement: "{{engagement_id}}"
source: discovery
tags: [zone-sweep, intake, "engagement/{{engagement_id}}", "phase/discovery"]
---

# Zone Sweep: {{network_cidr}} ({{segment_name}})

## Scan Metadata

| Field | Value |
|-------|-------|
| Network | {{network_cidr}} |
| Segment Name | {{segment_name}} |
| Scan Date | {{scan_date}} |
| Source | {{scan_source}} |
| Foothold Host | {{foothold_hostname}} |
| Agent ID | {{agent_id}} |
| Engagement | {{engagement_id}} |

## Hosts Discovered

<!-- One row per host responding to sweep.
     Mark Providentia column: yes = known to range inventory, no = rogue/unknown.
     Status: up | filtered | no-response.
-->

| IP | Hostname | OS (fingerprint) | Providentia | Status | Notes |
|----|----------|-------------------|-------------|--------|-------|
<!-- {{host_rows}} -->

**Total hosts up**: {{hosts_up_count}}
**Providentia expected**: {{providentia_expected_count}}
**Rogue / unknown**: {{rogue_count}}

## Open Ports & Services

<!-- One row per open port found during sweep.
     Protocol: tcp | udp. Service: banner or nmap service name.
     Version: service version string if available.
-->

| IP | Port | Protocol | Service | Version | Notes |
|----|------|----------|---------|---------|-------|
<!-- {{port_rows}} -->

## Providentia Reconciliation

<!-- Compare sweep results against range_targets / range_networks.
     Discrepancies are high-value findings. -->

### Hosts in Providentia but NOT responding

| Hostname | Expected IP | Expected Services | Possible Reason |
|----------|-------------|-------------------|-----------------|
<!-- {{missing_hosts_rows}} -->

### Hosts responding but NOT in Providentia

| IP | Hostname (if resolved) | Ports Open | Assessment |
|----|------------------------|------------|------------|
<!-- {{rogue_hosts_rows}} -->

### Service Discrepancies

<!-- Expected vs actual services on known hosts -->

| Hostname | Expected Service | Actual Service | Delta |
|----------|------------------|----------------|-------|
<!-- {{service_delta_rows}} -->

## Network Notes

<!-- Routing observations, VLAN tags, gateway IPs, DNS behavior,
     anything relevant to lateral movement planning. -->

## Related Pages

- Engagement: [[{{engagement_id}}]]
- Foothold target: [[{{foothold_hostname}}]]
