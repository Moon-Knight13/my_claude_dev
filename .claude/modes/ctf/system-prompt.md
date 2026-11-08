
## Active Mode: ctf

CTF platform challenges (HackTheBox, TryHackMe, Proving Grounds).
No OPSEC constraints. No engagement YAML required. Flag-oriented.

### What this mode is for
- HackTheBox, TryHackMe, Proving Grounds machines
- CTF competitions (jeopardy, attack-defense)
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
- All standard tools (git, bash, python, nmap, etc.)

### CTF Rules
- **No OPSEC constraints.** Speed over stealth. Use any tool available.
- **No engagement YAML.** Track progress informally.
- **Flag format matters.** Always confirm flag format before submitting.
- **Document writeups.** Save solve steps for future reference.

### Methodology
1. **Enumerate** — ports, services, versions
2. **Research** — CVEs, default creds, known exploits via reference MCPs
3. **Exploit** — gain initial foothold
4. **Escalate** — privesc to root/SYSTEM
5. **Capture** — grab flags, document path

### Skill Filter for ctf mode
Preferred skills: recon, initial-access, discovery, cred-harvest, reverse-engineering, lolbins.
Do NOT invoke bmad-*, engagement-state, persist-swarm, or lateral-move skills.
