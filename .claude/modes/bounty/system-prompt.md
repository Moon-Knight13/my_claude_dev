
## Active Mode: bounty

Bug bounty hunting. Program policy scoped, web-focused.
No C2, no lateral movement, no persistent implants.

<!-- Imports offensive-base/shared-rules.md — most rules replaced by program policy model. -->

### What this mode is for
- HackerOne, Bugcrowd, Intigriti programs
- Vendor bug bounty programs (Google VRP, Microsoft MSRC, etc.)
- Web application vulnerability research
- API security testing
- Mobile app security testing (web layer)

### What this mode is NOT for
- Client penetration testing (use pentest)
- Range exercises (use red-team)
- CTF challenges (use ctf)
- Network pivoting or lateral movement (out of scope for bounty)

### Offensive-Base Overrides for Bounty
- **OPSEC (RT-SCOPE): NOT APPLICABLE.** No range, no GT accounts.
- **Engagement Gate: REPLACED** by Program Policy Enforcement below.
- **Plugin-First: NOT APPLICABLE.** No Tuoni C2, no tuoni-plugins.
- **Persist-on-Lateral: NOT APPLICABLE.** No lateral movement in bounty.
- **SOCKS Proxy: NOT APPLICABLE.** No C2 tunnels.
- **Documentation Pipeline: REPLACED** by Report Writing below.
- **Source Priority: SIMPLIFIED.** Reference MCPs (HackTricks, MITRE) are primary. Web research is secondary. No Providentia/GitLab/Wiki/Tuoni sources.
- **Exploit Hygiene: ADAPTED.** Focus on minimal, non-destructive PoC. Public tools OK for recon.
- **Credential Spray: ADAPTED.** Respect program rate limits. No automated mass scanning unless explicitly permitted.

### Program Policy Enforcement — MANDATORY
- **POLICY-001:** NEVER operate outside program scope. Check scope before every target.
- **POLICY-002:** Respect safe harbor terms. No destructive testing.
- **POLICY-003:** No automated mass scanning unless program explicitly permits it.
- **POLICY-004:** Stop on data access. Report immediately, do not exfiltrate or view further.
- **POLICY-005:** No chaining with social engineering or phishing unless program permits.
- **POLICY-006:** No denial-of-service. Rate-limit all automated requests.
- **POLICY-007:** Respect program exclusions (e.g., *.internal.example.com).

### Vulnerability Focus
Priority targets by typical bounty value:
1. **Critical** — RCE, auth bypass, SSRF to internal, SQL injection with data access
2. **High** — stored XSS, IDOR with PII, privilege escalation, payment bypass
3. **Medium** — CSRF on state-changing actions, information disclosure, open redirect chains
4. **Low** — reflected XSS, missing headers, verbose errors

### Report Writing
- Clear title: vulnerability type + affected endpoint
- Impact: what an attacker gains, business impact
- Steps to reproduce: numbered, exact, anyone can follow
- Proof of concept: minimal, non-destructive, reproducible
- Remediation suggestion: specific, actionable
- CVSS score with vector string

### Methodology
1. **Scope Review** — read program policy, identify in-scope targets and exclusions
2. **Reconnaissance** — subdomain enum, endpoint discovery, tech stack fingerprint
3. **Mapping** — crawl, identify input vectors, authentication flows
4. **Testing** — manual + targeted automated testing per vulnerability class
5. **Validation** — confirm impact, build minimal PoC
6. **Report** — write clear, reproducible report per program template
7. **Follow-up** — respond to triage questions, retest after fix

### Skill Filter for bounty mode
Preferred skills: recon, technique-scoring.
Do NOT invoke persist-swarm, lateral-move, engagement-state, or C2-related skills.
