from mcp.server.fastmcp import FastMCP
from dotenv import load_dotenv
from neo4j import GraphDatabase
import os
import logging

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

load_dotenv()

BLOODHOUND_URI = os.getenv("BLOODHOUND_URI", "bolt://localhost:7687")
BLOODHOUND_USERNAME = os.getenv("BLOODHOUND_USERNAME", "neo4j")
BLOODHOUND_PASSWORD = os.getenv("BLOODHOUND_PASSWORD", "bloodhound")

_driver = None
_driver_error = None


def _get_driver():
    """Lazy-init Neo4j driver on first use, not at import time."""
    global _driver, _driver_error
    if _driver is not None:
        return _driver
    if _driver_error is not None:
        raise _driver_error
    try:
        d = GraphDatabase.driver(
            BLOODHOUND_URI,
            auth=(BLOODHOUND_USERNAME, BLOODHOUND_PASSWORD),
            encrypted=False,
            connection_timeout=10,
            max_transaction_retry_time=5,
        )
        d.verify_connectivity()
        _driver = d
        logger.info("Neo4j driver connected to %s", BLOODHOUND_URI)
        return _driver
    except Exception as e:
        _driver_error = e
        logger.error("Neo4j connection failed: %s", e)
        raise


def _reset_driver():
    """Clear cached driver so next call retries connection."""
    global _driver, _driver_error
    if _driver is not None:
        try:
            _driver.close()
        except Exception:
            pass
    _driver = None
    _driver_error = None


mcp = FastMCP("BH-Examples")


@mcp.tool()
async def query_bloodhound(query: str):
    """Run a raw Cypher query against the BloodHound Neo4j database."""
    try:
        driver = _get_driver()
    except Exception as e:
        return {"success": False, "error": f"Neo4j unavailable: {e}"}

    databases = ["neo4j", "bloodhound"]
    last_error = None

    for db in databases:
        try:
            with driver.session(database=db) as session:
                result = session.run(query)
                data = [record.data() for record in result]
                logger.info(f"Query successful on database '{db}'")
                return {"success": True, "data": data}
        except Exception as e:
            last_error = e
            logger.debug(f"Query failed on database '{db}': {str(e)}")
            continue

    logger.error(f"Query failed on all databases. Last error: {str(last_error)}")
    return {"success": False, "error": str(last_error)}


@mcp.tool()
async def reconnect_bloodhound():
    """Reset and retry Neo4j connection. Use after Neo4j becomes available."""
    _reset_driver()
    try:
        _get_driver()
        return {"success": True, "message": "Reconnected to Neo4j"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# Domain Information
@mcp.tool()
async def find_all_domain_admins():
    query = """
    MATCH p = (t:Group)<-[:MemberOf*1..]-(a)
    WHERE (a:User or a:Computer) and t.objectid ENDS WITH '-512'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def map_domain_trusts():
    query = """
    MATCH p = (:Domain)-[:TrustedBy]->(:Domain)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_tier_zero_locations():
    query = """
    MATCH p = (t:Base)<-[:Contains*1..]-(:Domain)
    WHERE t.highvalue = true
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def map_ou_structure():
    query = """
    MATCH p = (:Domain)-[:Contains*1..]->(:OU)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Dangerous Privileges
@mcp.tool()
async def find_dcsync_privileges():
    query = """
    MATCH p=(:Base)-[:DCSync|AllExtendedRights|GenericAll]->(:Domain)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_foreign_group_memberships():
    query = """
    MATCH p=(s:Base)-[:MemberOf]->(t:Group)
    WHERE s.domainsid<>t.domainsid
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_local_admins():
    query = """
    MATCH p=(s:Group)-[:AdminTo]->(:Computer)
    WHERE s.objectid ENDS WITH '-513'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_laps_readers():
    query = """
    MATCH p=(s:Group)-[:AllExtendedRights|ReadLAPSPassword]->(:Computer)
    WHERE s.objectid ENDS WITH '-513'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_high_value_paths():
    query = """
    MATCH p=shortestPath((s:Group)-[r*1..]->(t))
    WHERE t.highvalue = true AND s.objectid ENDS WITH '-513' AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_workstation_rdp():
    query = """
    MATCH p=(s:Group)-[:CanRDP]->(t:Computer)
    WHERE s.objectid ENDS WITH '-513' AND NOT toUpper(t.operatingsystem) CONTAINS 'SERVER'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_server_rdp():
    query = """
    MATCH p=(s:Group)-[:CanRDP]->(t:Computer)
    WHERE s.objectid ENDS WITH '-513' AND toUpper(t.operatingsystem) CONTAINS 'SERVER'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_users_privileges():
    query = """
    MATCH p=(s:Group)-[r]->(:Base)
    WHERE s.objectid ENDS WITH '-513'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domain_admin_non_dc_logons():
    query = """
    MATCH (s)-[:MemberOf*0..]->(g:Group)
    WHERE g.objectid ENDS WITH '-516'
    WITH COLLECT(s) AS exclude
    MATCH p = (c:Computer)-[:HasSession]->(:User)-[:MemberOf*1..]->(g:Group)
    WHERE g.objectid ENDS WITH '-512' AND NOT c IN exclude
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Kerberos Interaction
@mcp.tool()
async def find_kerberoastable_tier_zero():
    query = """
    MATCH (u:User)
    WHERE u.hasspn=true
    AND u.enabled = true
    AND NOT u.objectid ENDS WITH '-502'
    AND NOT u.gmsa = true
    AND NOT u.msa = true
    AND u.highvalue = true
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_all_kerberoastable_users():
    query = """
    MATCH (u:User)
    WHERE u.hasspn=true
    AND u.enabled = true
    AND NOT u.objectid ENDS WITH '-502'
    AND NOT u.gmsa = true
    AND NOT u.msa = true
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_kerberoastable_most_admin():
    query = """
    MATCH (u:User)
    WHERE u.hasspn = true
      AND u.enabled = true
      AND NOT u.objectid ENDS WITH '-502'
      AND NOT u.gmsa = true
      AND NOT u.msa = true
    MATCH (u)-[:MemberOf|AdminTo*1..]->(c:Computer)
    WITH DISTINCT u, COUNT(c) AS adminCount
    RETURN u
    ORDER BY adminCount DESC
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_asreproast_users():
    query = """
    MATCH (u:User)
    WHERE u.dontreqpreauth = true
    AND u.enabled = true
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

# Shortest Paths
@mcp.tool()
async def find_shortest_paths_unconstrained_delegation():
    query = """
    MATCH p=shortestPath((s)-[r*1..]->(t:Computer))
    WHERE t.unconstraineddelegation = true AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_from_kerberoastable_to_da():
    query = """
    MATCH p=shortestPath((s:User)-[r*1..]->(t:Group))
    WHERE s.hasspn=true
    AND s.enabled = true
    AND NOT s.objectid ENDS WITH '-502'
    AND NOT s.gmsa = true
    AND NOT s.msa = true
    AND t.objectid ENDS WITH '-512'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_shortest_paths_to_tier_zero():
    query = """
    MATCH p=shortestPath((s)-[r*1..]->(t))
    WHERE t.highvalue = true AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_from_domain_users_to_tier_zero():
    query = """
    MATCH p=shortestPath((s:Group)-[r*1..]->(t))
    WHERE t.highvalue = true AND s.objectid ENDS WITH '-513' AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_shortest_paths_to_domain_admins():
    query = """
    MATCH p=shortestPath((t:Group)<-[r*1..]-(s:Base))
    WHERE t.objectid ENDS WITH '-512' AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_from_owned_objects():
    query = """
    MATCH p=shortestPath((s:Base)-[r*1..]->(t:Base))
    WHERE s.owned = true AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Active Directory Certificate Services
@mcp.tool()
async def find_pki_hierarchy():
    query = """
    MATCH p=()-[:HostsCAService|IssuedSignedBy|EnterpriseCAFor|RootCAFor|TrustedForNTAuth|NTAuthStoreFor*..]->(:Domain)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_public_key_services():
    query = """
    MATCH p = (c:Container)-[:Contains*..]->(:Base)
    WHERE c.distinguishedname starts with 'CN=PUBLIC KEY SERVICES,CN=SERVICES,CN=CONFIGURATION,DC='
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_certificate_enrollment_rights():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(:CertTemplate)-[:PublishedTo]->(:EnterpriseCA)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_esc1_vulnerable_templates():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(ct:CertTemplate)-[:PublishedTo]->(:EnterpriseCA)
    WHERE ct.enrolleesuppliessubject = True
    AND ct.authenticationenabled = True
    AND ct.requiresmanagerapproval = False
    AND (ct.authorizedsignatures = 0 OR ct.schemaversion = 1)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_esc2_vulnerable_templates():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(c:CertTemplate)-[:PublishedTo]->(:EnterpriseCA)
    WHERE c.requiresmanagerapproval = false
    AND (c.effectiveekus = [''] OR '2.5.29.37.0' IN c.effectiveekus)
    AND (c.authorizedsignatures = 0 OR c.schemaversion = 1)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_enrollment_agent_templates():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(ct:CertTemplate)-[:PublishedTo]->(:EnterpriseCA)
    WHERE '1.3.6.1.4.1.311.20.2.1' IN ct.effectiveekus
    OR '2.5.29.37.0' IN ct.effectiveekus
    OR SIZE(ct.effectiveekus) = 0
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_dcs_weak_certificate_binding():
    query = """
    MATCH p = (s:Computer)-[:DCFor]->(:Domain)
    WHERE s.strongcertificatebindingenforcementraw = 0 OR s.strongcertificatebindingenforcementraw = 1
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_inactive_tier_zero_principals():
    query = """
    WITH 60 as inactive_days
    MATCH (n:Base)
    WHERE n.highvalue = true
    AND n.enabled = true
    AND n.lastlogontimestamp < (datetime().epochseconds - (inactive_days * 86400))
    AND n.lastlogon < (datetime().epochseconds - (inactive_days * 86400))
    AND n.whencreated < (datetime().epochseconds - (inactive_days * 86400))
    AND NOT n.name STARTS WITH 'AZUREADKERBEROS.'
    AND NOT n.objectid ENDS WITH '-500'
    AND NOT n.name STARTS WITH 'AZUREADSSOACC.'
    RETURN n
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_tier_zero_without_smartcard():
    query = """
    MATCH (u:User)
    WHERE u.highvalue = true
    AND u.enabled = true
    AND u.smartcardrequired = false
    AND NOT u.name STARTS WITH 'MSOL_'
    AND NOT u.name STARTS WITH 'PROVAGENTGMSA'
    AND NOT u.name STARTS WITH 'ADSYNCMSA_'
    RETURN u
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_domains_with_machine_quota():
    query = """
    MATCH (d:Domain)
    WHERE d.machineaccountquota > 0
    RETURN d
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_smartcard_dont_expire_domains():
    query = """
    MATCH (s:Domain)-[:Contains*1..]->(t:Base)
    WHERE s.expirepasswordsonsmartcardonlyaccounts = false
    AND t.enabled = true
    AND t.smartcardrequired = true
    RETURN s
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_two_way_forest_trust_delegation():
    query = """
    MATCH p=(n:Domain)-[r:TrustedBy]->(m:Domain)
    WHERE (m)-[:TrustedBy]->(n)
    AND r.trusttype = 'Forest'
    AND r.tgtdelegationenabled = true
    RETURN p
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_unsupported_operating_systems():
    query = """
    MATCH (c:Computer)
    WHERE c.operatingsystem =~ '(?i).*Windows.* (2000|2003|2008|2012|xp|vista|7|8|me|nt).*'
    RETURN c
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_users_with_no_password_required():
    query = """
    MATCH (u:User)
    WHERE u.passwordnotreqd = true
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_users_password_not_rotated():
    query = """
    WITH 365 as days_since_change
    MATCH (u:User)
    WHERE u.pwdlastset < (datetime().epochseconds - (days_since_change * 86400))
    AND NOT u.pwdlastset IN [-1.0, 0.0]
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_nested_tier_zero_groups():
    query = """
    MATCH p=(t:Group)<-[:MemberOf*..]-(s:Group)
    WHERE t.highvalue = true
    AND NOT s.objectid ENDS WITH '-512'
    AND NOT s.objectid ENDS WITH '-519'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_disabled_tier_zero_principals():
    query = """
    MATCH (n:Base)
    WHERE n.highvalue = true
    AND n.enabled = false
    AND NOT n.objectid ENDS WITH '-502'
    AND NOT n.objectid ENDS WITH '-500'
    RETURN n
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_principals_reversible_encryption():
    query = """
    MATCH (n:Base)
    WHERE n.encryptedtextpwdallowed = true
    RETURN n
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_principals_des_only_kerberos():
    query = """
    MATCH (n:Base)
    WHERE n.enabled = true
    AND n.usedeskeyonly = true
    RETURN n
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_principals_weak_kerberos_encryption():
    query = """
    MATCH (u:Base)
    WHERE 'DES-CBC-CRC' IN u.supportedencryptiontypes
    OR 'DES-CBC-MD5' IN u.supportedencryptiontypes
    OR 'RC4-HMAC-MD5' IN u.supportedencryptiontypes
    RETURN u
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_tier_zero_non_expiring_passwords():
    query = """
    MATCH (u:User)
    WHERE u.enabled = true
    AND u.pwdneverexpires = true
    AND u.highvalue = true
    RETURN u
    LIMIT 100
    """
    return await query_bloodhound(query)

# NTLM Relay Attacks
@mcp.tool()
async def find_ntlm_relay_edges():
    query = """
    MATCH p = (n:Base)-[:CoerceAndRelayNTLMToLDAP|CoerceAndRelayNTLMToLDAPS|CoerceAndRelayNTLMToADCS|CoerceAndRelayNTLMToSMB]->(:Base)
    RETURN p LIMIT 500
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_esc8_vulnerable_cas():
    query = """
    MATCH (n:EnterpriseCA)
    WHERE n.hasvulnerableendpoint=true
    RETURN n
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_computers_outbound_ntlm_deny():
    query = """
    MATCH (c:Computer)
    WHERE c.restrictoutboundntlm = True
    RETURN c LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_computers_in_protected_users():
    query = """
    MATCH p = (:Base)-[:MemberOf*1..]->(g:Group)
    WHERE g.objectid ENDS WITH "-525"
    RETURN p LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_dcs_vulnerable_ntlm_relay():
    query = """
    MATCH p = (dc:Computer)-[:DCFor]->(:Domain)
    WHERE (dc.ldapavailable = True AND dc.ldapsigning = False)
    OR (dc.ldapsavailable = True AND dc.ldapsepa = False)
    OR (dc.ldapavailable = True AND dc.ldapsavailable = True AND dc.ldapsigning = False and dc.ldapsepa = True)
    RETURN p
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_computers_webclient_running():
    query = """
    MATCH (c:Computer)
    WHERE c.webclientrunning = True
    RETURN c LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_computers_no_smb_signing():
    query = """
    MATCH (n:Computer)
    WHERE n.smbsigning = False
    RETURN n
    """
    return await query_bloodhound(query)

# Azure - General
@mcp.tool()
async def find_global_administrators():
    query = """
    MATCH p = (:AZBase)-[:AZGlobalAdmin*1..]->(:AZTenant)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_high_privileged_role_members():
    query = """
    MATCH p=(t:AZRole)<-[:AZHasRole|AZMemberOf*1..2]-(:AZBase)
    WHERE t.name =~ '(?i)(Global Administrator|User Access Administrator|Privileged Role Administrator|Privileged Authentication Administrator|Partner Tier1 Support|Partner Tier2 Support)'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Azure - Shortest Paths
@mcp.tool()
async def find_paths_from_entra_to_tier_zero():
    query = """
    MATCH p=shortestPath((s:AZUser)-[r*1..]->(t:AZBase))
    WHERE t.highvalue = true AND t.name =~ '(?i)(Global Administrator|User Access Administrator|Privileged Role Administrator|Privileged Authentication Administrator|Partner Tier1 Support|Partner Tier2 Support)' AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_to_privileged_roles():
    query = """
    MATCH p=shortestPath((s:AZBase)-[r*1..]->(t:AZRole))
    WHERE t.name =~ '(?i)(Global Administrator|User Access Administrator|Privileged Role Administrator|Privileged Authentication Administrator|Partner Tier1 Support|Partner Tier2 Support)' AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_from_azure_apps_to_tier_zero():
    query = """
    MATCH p=shortestPath((s:AZApp)-[r*1..]->(t:AZBase))
    WHERE t.highvalue = true AND s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_paths_to_azure_subscriptions():
    query = """
    MATCH p=shortestPath((s:AZBase)-[r*1..]->(t:AZSubscription))
    WHERE s<>t
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Azure - Microsoft Graph
@mcp.tool("sp_app_role_grant")
async def find_service_principals_with_app_role_grant():
    query = """
    MATCH p=(:AZServicePrincipal)-[:AZMGGrantAppRoles]->(:AZTenant)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("find_sp_graph_assignments")
async def find_service_principals_with_graph_assignments():
    query = """
    MATCH p=(:AZServicePrincipal)-[:AZMGAppRoleAssignment_ReadWrite_All|AZMGApplication_ReadWrite_All|AZMGDirectory_ReadWrite_All|AZMGGroupMember_ReadWrite_All|AZMGGroup_ReadWrite_All|AZMGRoleManagement_ReadWrite_Directory|AZMGServicePrincipalEndpoint_ReadWrite_All]->(:AZServicePrincipal)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

# Azure - Hygiene
@mcp.tool()
async def find_foreign_tier_zero_principals():
    query = """
    MATCH (n:AZServicePrincipal)
    WHERE n.highvalue = true
    AND NOT toUpper(n.appownerorganizationid) = toUpper(n.tenantid)
    AND n.appownerorganizationid CONTAINS '-'
    RETURN n
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_synced_tier_zero_principals():
    query = """
    MATCH (ENTRA:AZBase)
    MATCH (AD:Base)
    WHERE ENTRA.onpremsyncenabled = true
    AND ENTRA.onpremid = AD.objectid
    AND AD.highvalue = true
    RETURN ENTRA
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_external_tier_zero_users():
    query = """
    MATCH (n:AZUser)
    WHERE n.highvalue = true
    AND n.name CONTAINS '#EXT#@'
    RETURN n
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_disabled_azure_tier_zero_principals():
    query = """
    MATCH (n:AZBase)
    WHERE n.highvalue = true
    AND n.enabled = false
    RETURN n
    LIMIT 100
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_devices_unsupported_os():
    query = """
    MATCH (n:AZDevice)
    WHERE n.operatingsystem CONTAINS 'WINDOWS'
    AND n.operatingsystemversion =~ '(10.0.19044|10.0.22000|10.0.19043|10.0.19042|10.0.19041|10.0.18363|10.0.18362|10.0.17763|10.0.17134|10.0.16299|10.0.15063|10.0.14393|10.0.10586|10.0.10240|6.3.9600|6.2.9200|6.1.7601|6.0.6200|5.1.2600|6.0.6003|5.2.3790|5.0.2195).?.*'
    RETURN n
    LIMIT 100
    """
    return await query_bloodhound(query)

# Azure - Cross Platform Attack Paths
@mcp.tool()
async def find_entra_users_in_domain_admins():
    query = """
    MATCH p = (:AZUser)-[:SyncedToADUser]->(:User)-[:MemberOf]->(t:Group)
    WHERE t.objectid ENDS WITH '-512'
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_onprem_users_owning_entra_objects():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZOwns]->(:AZBase)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_onprem_users_in_entra_groups():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZMemberOf]->(:AZGroup)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("templates_no_security_ext")
async def find_templates_no_security_extension():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(ct:CertTemplate)-[:PublishedTo]->(:EnterpriseCA)
    WHERE ct.nosecurityextension = true
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("templates_with_user_san")
async def find_templates_with_user_specified_san():
    query = """
    MATCH p = (:Base)-[:Enroll|GenericAll|AllExtendedRights]->(ct:CertTemplate)-[:PublishedTo]->(eca:EnterpriseCA)
    WHERE eca.isuserspecifiessanenabled = True
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool()
async def find_ca_administrators():
    query = """
    MATCH p = (:Base)-[:ManageCertificates|ManageCA]->(:EnterpriseCA)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("onprem_users_direct_entra_roles")
async def find_onprem_users_with_direct_entra_roles():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZHasRole]->(:AZRole)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("onprem_users_group_entra_roles")
async def find_onprem_users_with_group_entra_roles():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZMemberOf]->(:AZGroup)-[:AZHasRole]->(:AZRole)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("onprem_users_direct_azure_roles")
async def find_onprem_users_with_direct_azure_roles():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZOwner|AZUserAccessAdministrator|AZGetCertificates|AZGetKeys|AZGetSecrets|AZAvereContributor|AZKeyVaultContributor|AZContributor|AZVMAdminLogin|AZVMContributor|AZAKSContributor|AZAutomationContributor|AZLogicAppContributor|AZWebsiteContributor]->(:AZBase)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

@mcp.tool("onprem_users_group_azure_roles")
async def find_onprem_users_with_group_azure_roles():
    query = """
    MATCH p = (:User)-[:SyncedToEntraUser]->(:AZUser)-[:AZMemberOf]->(:AZGroup)-[:AZOwner|AZUserAccessAdministrator|AZGetCertificates|AZGetKeys|AZGetSecrets|AZAvereContributor|AZKeyVaultContributor|AZContributor|AZVMAdminLogin|AZVMContributor|AZAKSContributor|AZAutomationContributor|AZLogicAppContributor|AZWebsiteContributor]->(:AZBase)
    RETURN p
    LIMIT 1000
    """
    return await query_bloodhound(query)

if __name__ == "__main__":
    try:
        logger.info("Starting BloodHound MCP server (Neo4j connection deferred to first tool call)...")
        mcp.run(transport="stdio")
    finally:
        if _driver is not None:
            _driver.close()
