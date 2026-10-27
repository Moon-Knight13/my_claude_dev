"""Pydantic data models for range-intel MCP."""

from __future__ import annotations

from pydantic import BaseModel, Field


class Environment(BaseModel):
    id: str
    name: str


class Address(BaseModel):
    pool_id: str | None = None
    mode: str | None = None
    connection: bool = False
    address: str | None = None
    dns_enabled: bool = False
    gateway: str | None = None


class Interface(BaseModel):
    network_id: str | None = None
    cloud_id: str | None = None
    domain: str | None = None
    fqdn: str | None = None
    egress: bool = False
    connection: bool = False
    addresses: list[Address] = Field(default_factory=list)


class HostInstance(BaseModel):
    id: str
    parent_id: str | None = None
    vm_name: str | None = None
    team_unique_id: str | None = None
    hostname: str | None = None
    domain: str | None = None
    fqdn: str | None = None
    connection_address: str | None = None
    interfaces: list[Interface] = Field(default_factory=list)
    team_nr: int | None = None
    team_nr_str: str | None = None
    actor_nr: int | None = None
    actor_nr_str: str | None = None
    config_map: dict | None = None


class Host(BaseModel):
    id: str
    spec_name: str | None = None
    owner: str | None = None
    description: str | None = None
    role: str | None = None
    actor_id: str | None = None
    actor_name: str | None = None
    visibility: str | None = None
    tags: list[str] = Field(default_factory=list)
    instances: list[HostInstance] = Field(default_factory=list)


class NetworkPool(BaseModel):
    id: str | None = None
    ip_family: str | None = None
    network_address: str | None = None
    gateway: str | None = None


class NetworkInstance(BaseModel):
    cloud_id: str | None = None
    domains: list[str] = Field(default_factory=list)
    address_pools: list[NetworkPool] = Field(default_factory=list)
    config_map: dict | None = None


class Network(BaseModel):
    id: str
    name: str | None = None
    description: str | None = None
    team: str | None = None
    instances: list[NetworkInstance] = Field(default_factory=list)


class Tag(BaseModel):
    id: str
    name: str | None = None
    config_map: dict = Field(default_factory=dict)
    children: list[str] = Field(default_factory=list)


class ImplementedVuln(BaseModel):
    name: str
    category: str | None = None
    description: str | None = None
    abuse_steps: list[str] = Field(default_factory=list)
    parameters: dict = Field(default_factory=dict)


class VMProfile(BaseModel):
    directory: str
    box_name: str | None = None
    category: str | None = None
    platform: str | list[str] | None = None
    domains: list[str] = Field(default_factory=list)
    contains_vulns: list[str] = Field(default_factory=list)
    vuln_paths: list[str] = Field(default_factory=list)
    mitre_attack_ids: list[str] = Field(default_factory=list)
    last_updated: str | None = None
    implemented_vulns: list[ImplementedVuln] = Field(default_factory=list)
    raw_body: str | None = None


class MergedTarget(BaseModel):
    host_id: str
    spec_name: str | None = None
    role: str | None = None
    platform: str | list[str] | None = None
    tags: list[str] = Field(default_factory=list)
    instance: HostInstance | None = None
    vulns: list[ImplementedVuln] = Field(default_factory=list)
    mitre_attack_ids: list[str] = Field(default_factory=list)
    match_method: str | None = None
    vm_profile: VMProfile | None = None
