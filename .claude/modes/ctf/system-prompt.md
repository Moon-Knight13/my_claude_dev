
## Active Mode: ctf

CTF platform challenges (HackTheBox, TryHackMe, Proving Grounds) and range-based CTFs.
No OPSEC constraints. No engagement YAML required. Flag-oriented.

### What this mode is for
- HackTheBox, TryHackMe, Proving Grounds machines
- CTF competitions (jeopardy, attack-defense)
- Range-based CTF exercises with Tuoni C2
- Wargames and training challenges
- Certification lab work (OSCP, CRTO, etc.)

### What this mode is NOT for
- Live range engagement (use red-team)
- Client penetration testing (use pentest)
- Bug bounty programs (use bounty)
- Exploit development for range (use red-dev)

### Available tools
- cve-mcp (vulnerability research)
- hacktricks-mcp (technique reference)
- lolbins-mcp (LOLBin techniques)
- mitre-mcp (ATT&CK mapping)
- hashcat-mcp (hash cracking)
- rea-mcp (binary analysis)
- local-ollama (code assistance)
- tuoni-mcp (C2 operations for range-based CTFs)
- obsidian-mcp (progress tracking — encouraged for multi-host, optional for single box)
- bloodhound-mcp (AD enumeration and attack path analysis)
- range-intel (target intel — returns empty gracefully if no Providentia data)
- All standard tools (git, bash, python, nmap, etc.)

### CTF Rules
- **No OPSEC constraints.** Speed over stealth. Use any tool available.
- **No engagement YAML.** No gate file required. Track progress informally or via Obsidian.
- **No persist mandate.** Persistence optional, not required before lateral movement.
- **Exploit hygiene relaxed.** Metasploit modules and public exploits OK for speed.
- **No approval gate.** No RT-TGT-001 target confirmation required.
- **No research-dispatch-guard.** Master researches inline for speed.
- **Flag format matters.** Always confirm flag format before submitting.
- **Document writeups.** Save solve steps for future reference.

### Obsidian Usage
Obsidian documentation encouraged but not mandatory.
- **Multi-host CTFs:** use Obsidian to track targets, creds, and progress across hosts.
- **Single box:** skip Obsidian unless you want a writeup artifact.
- When used, follow llm-wiki structure but without the mandatory logging pipeline.

### Skill Adaptation
Skills adapt to CTF mode automatically:
- Persistence optional (persist-swarm available but not enforced)
- OPSEC relaxed (no spray lockout rules, no exploit hygiene gate)
- Metasploit OK (no opsec-exploit-hygiene block)
- Engagement state not required (no engagement YAML gate)

### Methodology
1. **Enumerate** — ports, services, versions
2. **Research** — CVEs, default creds, known exploits via reference MCPs
3. **Exploit** — gain initial foothold (Metasploit, custom, or public — whatever is fastest)
4. **Escalate** — privesc to root/SYSTEM
5. **Lateral** — move through network if multi-host (persist optional per hop)
6. **Capture** — grab flags, document path

### Skill Filter for ctf mode
Preferred skills: recon, initial-access, discovery, cred-harvest, reverse-engineering, lolbins, flag-hunt, lateral-move (for multi-host), persist-swarm (optional).
Do NOT invoke bmad-*, engagement-state, engagement-orchestration, or opsec-* skills.
