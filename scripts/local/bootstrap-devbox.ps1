<#
.SYNOPSIS
    Windows bootstrap for connecting to a remote dev box (mirrors bootstrap-devbox.sh).
.DESCRIPTION
    Ensures the OpenSSH agent is running, REUSES a key the git server already
    accepts (generating a dedicated per-machine key only when there is nothing to
    reuse), writes an idempotent ~/.ssh/config Host block, copies the public key
    to the box for passwordless login, installs the VSCode Remote-SSH extension,
    sets remote.SSH.useExecServer=false, and verifies which identity the git
    server actually returns — pinning on the box only if the box gets it wrong.

    Prompts for per-dev values and the box login password LIVE — nothing secret is
    ever written into the repo.

    SCOPE NOTE: like the .sh sibling, the identity pin writes to the BOX — a
    PUBLIC key and an ssh_config ALIAS block. Never private key material, and
    never a default `Host` entry: the box account is shared.

    KNOWN GAP vs the .sh sibling: Windows OpenSSH uses named pipes, not socket
    paths, so `ForwardAgent <path>` (the scoped-agent containment fix) has no
    equivalent here. This script forwards the whole agent and says so. Do not
    read a scoped forward into it.
.NOTES
    Requires the latest OpenSSH for Windows so SSH agent forwarding works:
    https://github.com/PowerShell/Win32-OpenSSH/releases/
    Enable the agent (admin PowerShell, once):
        Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\local\bootstrap-devbox.ps1
#>
[CmdletBinding()]
param(
    # Every site-specific value is prompted for or read from an env var — this
    # repo is public, so none of them are baked in.
    [string]$DevboxNum  = $env:DEVBOX_NUM,
    [string]$BoxUser    = $env:DEVBOX_USER,
    [string]$Domain     = $env:DEVBOX_DOMAIN,
    [string]$HostPrefix = $env:DEVBOX_PREFIX,
    [string]$RangeUser  = $env:RANGE_USER,
    [string]$MachineName= $env:DEVBOX_MACHINE,
    [string]$GitHost    = $env:DEVBOX_GIT_HOST,
    [string]$GitSshPort = $env:DEVBOX_GIT_SSH_PORT,
    [string]$GitAlias   = $(if ($env:DEVBOX_GIT_ALIAS) { $env:DEVBOX_GIT_ALIAS } else { "devbox-git" }),
    # Point at an existing key to skip discovery entirely.
    [string]$SshKey     = $env:SSH_KEY,
    # Reverse tunnel that carries this machine's model endpoint to the box.
    [string]$LocalModelPort  = $env:LOCAL_MODEL_PORT,
    [string]$RemoteModelPort = $env:REMOTE_MODEL_PORT
)

$ErrorActionPreference = "Stop"
function Info($m) { Write-Host "  ++  $m" }
function Note($m) { Write-Host "  --  $m" }
function Warn($m) { Write-Warning $m }
function Step($m) { Write-Host ""; Write-Host ">> $m" }
function Confirm($m) { $r = Read-Host "  ??  $m [y/N]"; return $r -match '^[Yy]' }
function Sanitise($s) { return ($s -replace '[^A-Za-z0-9._-]', '_') }

Step "Remote dev box local bootstrap (Windows)"

# 1. Prompt for per-dev values
if (-not $DevboxNum) { $DevboxNum = Read-Host "  ??  Box number (e.g. 07)" }
if (-not $DevboxNum) { throw "box number required" }
if (-not $RangeUser) {
    $d = Read-Host "  ??  Your username on the box [$env:USERNAME]"
    $RangeUser = if ($d) { $d } else { $env:USERNAME }
}
if (-not $Domain) { $Domain = Read-Host "  ??  Box domain (e.g. dev.example.net)" }
if (-not $Domain) { throw "domain required (set DEVBOX_DOMAIN or answer the prompt)" }
if (-not $HostPrefix) { $HostPrefix = Read-Host "  ??  Box hostname prefix, before the number (e.g. devbox)" }
if (-not $HostPrefix) { throw "hostname prefix required (set DEVBOX_PREFIX or answer the prompt)" }
if (-not $BoxUser) { $BoxUser = Read-Host "  ??  Login account on the box (shared account)" }
if (-not $BoxUser) { throw "box account required (set DEVBOX_USER or answer the prompt)" }

# Git server details come EARLY: key selection asks the git server which key it
# already knows rather than generating a competing one.
if (-not $GitHost) {
    $d = Read-Host "  ??  Git server hostname [git.$Domain]"
    $GitHost = if ($d) { $d } else { "git.$Domain" }
}
# No default port. A site on a non-standard SSH port got '22' silently on every
# run, and a wrong port fails in a way that looks like an auth problem.
if (-not $GitSshPort) { $GitSshPort = Read-Host "  ??  Git server SSH port (OpenSSH default is 22; check your site)" }
if ($GitSshPort -notmatch '^\d+$') { throw "git server SSH port required (numeric)" }

$BoxHost = "$HostPrefix$DevboxNum.$Domain"
$Alias   = "$HostPrefix$DevboxNum"
Info "Target: $BoxUser@$BoxHost"

# 2. Identity string — <range-user>_<machine>. Two machines otherwise produce two
#    keys with identical comments, indistinguishable in the server's key list.
Step "Identity"
if (-not $MachineName) {
    $d = Read-Host "  ??  Short name for THIS machine [$env:COMPUTERNAME]"
    $MachineName = if ($d) { $d } else { $env:COMPUTERNAME }
}
$Identity = Sanitise "$($RangeUser)_$($MachineName)"
if (-not $Identity) { throw "could not build an identity string" }
$KeyComment = if ($env:KEY_COMMENT) { $env:KEY_COMMENT } else { $Identity }
$ManagedKey = Join-Path $HOME ".ssh\id_ed25519_$Identity"
Info "identity: $Identity"

# 3. SSH agent
Step "SSH agent"
try {
    $svc = Get-Service ssh-agent -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Note "starting ssh-agent (may need: Set-Service ssh-agent -StartupType Automatic in an admin shell)"
        Start-Service ssh-agent
    }
    Info "ssh-agent running"
} catch {
    Warn "ssh-agent service not available. Install latest Win32-OpenSSH and run (admin): Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent"
}

# 4. SSH keypair — REUSE what the git server already knows.
#    Generating unconditionally is what manufactures the fault this script exists
#    to prevent: a developer holding a registered key gains a second,
#    UNREGISTERED identity competing for position in agent order. ssh offers agent
#    keys in order and stops at the first the server accepts, so the identity you
#    authenticate as becomes emergent rather than declared.
#    This previously hardcoded ~/.ssh/id_ed25519 — the developer's DEFAULT
#    identity — and could generate over it. It no longer touches that key.
Step "SSH keypair"
function Probe-Key([string]$k) {
    $out = & ssh -o IdentitiesOnly=yes -i "$k" -o BatchMode=yes `
                 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
                 -p $GitSshPort -T "git@$GitHost" 2>&1
    return ($out | Where-Object { $_ -notmatch '^debug' } | Select-Object -First 1)
}

$Key = $null
$NeedsRegistration = $false
if ($SshKey) {
    if (-not (Test-Path $SshKey)) { throw "SSH_KEY=$SshKey does not exist" }
    $Key = $SshKey
    Info "using SSH_KEY override: $Key"
} else {
    Note "asking $GitHost which of your existing keys it already knows"
    $candidates = Get-ChildItem (Join-Path $HOME ".ssh") -Filter "*.pub" -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.FullName -replace '\.pub$', '' } |
                  Where-Object { Test-Path $_ } | Sort-Object
    foreach ($c in $candidates) {
        $greeting = Probe-Key $c
        if ($greeting -and $greeting -notmatch 'Permission denied|no such identity') {
            Info "$(Split-Path $c -Leaf) -> $greeting"
            if (Confirm "reuse $(Split-Path $c -Leaf) as your git identity?") { $Key = $c; break }
        }
    }
}
if (-not $Key) {
    if (Test-Path $ManagedKey) {
        Info "reusing existing managed key: $ManagedKey"
        $Key = $ManagedKey
    } else {
        Note "no key that $GitHost already accepts — generating one for this machine"
        Note "(you will set a passphrase; it is never stored by this script)"
        ssh-keygen -t ed25519 -C "$KeyComment" -f "$ManagedKey"
        $Key = $ManagedKey
        $NeedsRegistration = $true
    }
}
Info "git identity key: $Key"
ssh-add "$Key" 2>$null | Out-Null

# Agent population is not cosmetic: with several keys, WHICH identity you
# authenticate as is decided by agent order, and a wrong identity authenticates
# SUCCESSFULLY — nothing surfaces until a push is refused.
$agentKeys = @(ssh-add -l 2>$null | Where-Object { $_ -match '\S' })
if ($agentKeys.Count -gt 1) {
    Warn "agent holds $($agentKeys.Count) keys — identity is decided by agent ORDER, not by intent"
    $agentKeys | ForEach-Object { Write-Host "       $_" }
    Note "the verification step below reports which identity the git server actually returns."
    if ($agentKeys.Count -ge 6) {
        Warn "at $($agentKeys.Count) keys you are at or past the server's usual MaxAuthTries (6):"
        Note "each key offered and rejected burns one attempt, so the right key can be cut off"
        Note "before it is ever reached. Pinning removes that risk."
    }
}

# 5. Copy public key (prompts for password once).
#    Runs BEFORE the Host block is written, addressing the box directly, so the
#    tunnel-port probe below can reach it without a second password prompt.
Step "Passwordless login"
Note "you'll be asked for your box login password ONCE (entered live, never stored)"
$pub = Get-Content "$Key.pub"
$remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
$pub | ssh "$BoxUser@$BoxHost" $remoteCmd
if ($LASTEXITCODE -eq 0) { Info "public key installed on $BoxHost" } else { Warn "key copy failed — add $Key.pub to authorized_keys manually" }

# 6. Reverse tunnel for the local model endpoint.
#    The models run on THIS machine. The box has no endpoint of its own, so every
#    routing decision there falls through to Claude — silently, because the
#    fallback is indistinguishable from a deliberate choice in the log.
#
#    Exposure: the forwarded port is bound on the box's LOOPBACK only (sshd's
#    GatewayPorts defaults to no). It is still reachable by anyone with a shell on
#    that box while your session is open — the account is shared, so that is every
#    colleague. Nothing authenticates to it. Set LOCAL_MODEL_TUNNEL=false to skip.
Step "Local model tunnel"
$TunnelLine = ""
if ($env:LOCAL_MODEL_TUNNEL -and $env:LOCAL_MODEL_TUNNEL -ne "true") {
    Note "LOCAL_MODEL_TUNNEL is not 'true' — skipping (local routing stays off on the box)"
} else {
    if (-not $LocalModelPort) {
        $d = Read-Host "  ??  Local model port on THIS machine [11434]"
        $LocalModelPort = if ($d) { $d } else { "11434" }
    }
    $alive = $false
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalModelPort" -TimeoutSec 2 -UseBasicParsing
        $alive = $true
    } catch {
        # A model server that answers with a non-2xx status is still a server.
        if ($_.Exception.Response) { $alive = $true }
    }
    if (-not $alive) {
        Warn "nothing answers on http://127.0.0.1:$LocalModelPort on this machine"
        Note "not writing a tunnel to a dead endpoint. Start the model server, then re-run."
        Note "the box will keep routing everything to Claude until then."
    } else {
        if (-not $RemoteModelPort) { $RemoteModelPort = $LocalModelPort }
        # A collision on a shared box is worse than a failed bind: if a colleague
        # already forwards this port, sshd refuses yours and the endpoint that
        # answers on the box is THEIRS — your prompts would leave for another
        # developer's machine. Detect it rather than discover it later.
        function Test-RemotePort([string]$port) {
            $probe = "ss -ltn 2>/dev/null | awk '{print `$4}' | grep -qE '[:.]$port`$' && echo BOUND"
            $out = & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$BoxUser@$BoxHost" $probe 2>$null
            return ($out -match 'BOUND')
        }
        if (Test-RemotePort $RemoteModelPort) {
            Warn "port $RemoteModelPort is ALREADY bound on the box"
            Note "that is most likely another developer's tunnel. Using it would send your"
            Note "prompts to THEIR machine, and your own bind would be refused."
            $d = Read-Host "  ??  Different port to use on the box [$([int]$RemoteModelPort + 1)]"
            $RemoteModelPort = if ($d) { $d } else { [string]([int]$RemoteModelPort + 1) }
            if (Test-RemotePort $RemoteModelPort) {
                Warn "port $RemoteModelPort is also bound — pick one by hand and re-run"
                $RemoteModelPort = ""
            }
        }
        if ($RemoteModelPort) {
            $TunnelLine = "`n    RemoteForward 127.0.0.1:$RemoteModelPort 127.0.0.1:$LocalModelPort"
            Info "tunnel: box 127.0.0.1:$RemoteModelPort -> this machine 127.0.0.1:$LocalModelPort"
        }
    }
}

# 7. ~/.ssh/config Host block (idempotent)
Step "~/.ssh/config"
$sshDir = Join-Path $HOME ".ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$cfg = Join-Path $sshDir "config"
if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg | Out-Null }
if (Select-String -Path $cfg -Pattern "^\s*Host\s+.*\b$Alias\b" -Quiet) {
    Info "Host '$Alias' already in config — leaving as-is"
    Note "if it lacks 'IdentityFile $Key', add it: box login should not depend on agent order either"
    if ($TunnelLine) {
        Note "and add this line to carry the local model endpoint to the box:"
        Note "  $($TunnelLine.Trim())"
    }
} else {
    # ForwardAgent yes forwards EVERY key in the agent. Windows OpenSSH has no
    # socket-path form to scope it — stated, not papered over.
    Add-Content $cfg "`nHost $Alias $BoxHost`n    HostName $BoxHost`n    User $BoxUser`n    IdentityFile $Key`n    ForwardAgent yes$TunnelLine"
    Info "added Host '$Alias' -> $BoxUser@$BoxHost (ForwardAgent yes)"
    Note "ForwardAgent yes exposes ALL agent keys to the box for the session. The box"
    Note "account is shared with sudo for all; scoping is not available on Windows."
}

# 8. Local VSCode
Step "Local VSCode (Remote-SSH)"
$code = Get-Command code -ErrorAction SilentlyContinue
if ($code) {
    code --install-extension ms-vscode-remote.remote-ssh 2>$null | Out-Null
    Info "Remote-SSH extension present"
    $us = Join-Path $env:APPDATA "Code\User\settings.json"
    if (-not (Test-Path $us)) { New-Item -ItemType File -Path $us -Force | Out-Null; Set-Content $us "{}" }
    try {
        $json = Get-Content $us -Raw | ConvertFrom-Json
        if (-not $json) { $json = [pscustomobject]@{} }
        $json | Add-Member -NotePropertyName "remote.SSH.useExecServer" -NotePropertyValue $false -Force
        $json | Add-Member -NotePropertyName "remote.SSH.enableAgentForwarding" -NotePropertyValue $true -Force
        ($json | ConvertTo-Json -Depth 20) | Set-Content $us
        Info "set remote.SSH.useExecServer=false + remote.SSH.enableAgentForwarding=true"
    } catch {
        Note "could not edit settings.json automatically — set remote.SSH.useExecServer=false by hand"
    }
    # A configFile override means the Host block above is never read and
    # forwarding silently does not apply.
    if ((Test-Path $us) -and (Select-String -Path $us -Pattern "remote.SSH.configFile" -Quiet)) {
        Warn "remote.SSH.configFile is set in your VSCode settings — it OVERRIDES ~/.ssh/config"
        Note "either remove it, or add the Host block above to the file it points at"
    }
} else {
    Note "VSCode 'code' CLI not on PATH — install Remote-SSH from the Marketplace and set remote.SSH.useExecServer=false"
}

# 9. Register the public key at the git server
Step "Git server key (one-time, manual)"
if ($NeedsRegistration) { Warn "this key is NEW and the git server does not know it yet" }
else { Note "if you reused a key the server already accepted, this is already done" }
Write-Host "  --  Add $Key.pub at https://$GitHost/-/user_settings/ssh_keys (that path is GitLab's; adjust for a different git server)"
Write-Host "      test: ssh -T git@$GitHost -p $GitSshPort"
if (-not (Confirm "have you registered $Key.pub at $GitHost?")) {
    Warn "skipping identity verification — re-run this script after registering the key"
    exit 0
}

# 10. Verify the identity, and pin ONLY if the box gets it wrong.
#    A wrong identity authenticates SUCCESSFULLY; nothing errors until a push is
#    refused. Pinning a developer who does not need one adds configuration to a
#    shared account for no benefit.
Step "Identity verification"
$laptopId = Probe-Key $Key
Info "from this machine, pinned to $(Split-Path $Key -Leaf):"
Write-Host "       $laptopId"

$innerCmd = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p $GitSshPort -T git@$GitHost 2>&1 | head -1"
$boxId = (& ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $Alias $innerCmd 2>$null | Select-Object -First 1)
Info "from the box, unpinned (whichever key the agent offers first):"
Write-Host "       $(if ($boxId) { $boxId } else { '<no response — is the agent forwarded? run scripts/host/diagnose-git-auth.sh on the box>' })"

if ($boxId -and ($boxId -eq $laptopId)) {
    Info "the box already resolves to the same identity — NO pin needed"
    Note "leaving the box's ssh config untouched (it is a shared account)"
} else {
    Warn "the box does NOT resolve to the identity this machine uses"
    Note "cause: ssh offers agent keys in order and stops at the first the server accepts."
    Note "  Root-cause fix, if available: stop loading the competing key on this machine."
    Note "  Identify it by FINGERPRINT, never by filename, and RENAME rather than delete:"
    Note "      ssh-keygen -lf `$HOME\.ssh\<name>.pub     # confirm before touching anything"
    Note "  Otherwise, pin on the box: an ALIAS block, public keys only."
    if (Confirm "write the pinned alias '$GitAlias' to ${BoxUser}@${BoxHost}:~/.ssh/config?") {
        # Accumulative by design: one IdentityFile per registered machine, each
        # named for that machine, so a second machine adds exactly one line.
        $remotePin = @"
set -eu
cfg="`$HOME/.ssh/config"
mkdir -p "`$HOME/.ssh"; chmod 700 "`$HOME/.ssh"
touch "`$cfg"; chmod 600 "`$cfg"
chmod 644 "`$HOME/.ssh/$Identity.pub"
idline="    IdentityFile ~/.ssh/$Identity.pub"
if ! grep -qE "^[[:space:]]*Host[[:space:]]+$GitAlias([[:space:]]|`$)" "`$cfg"; then
    printf '\nHost %s\n    HostName %s\n    Port %s\n    User git\n    IdentitiesOnly yes\n%s\n' \
        "$GitAlias" "$GitHost" "$GitSshPort" "`$idline" >> "`$cfg"
    echo "  ++  added alias '$GitAlias' with $Identity"
elif grep -qF "`$idline" "`$cfg"; then
    echo "  --  alias '$GitAlias' already lists $Identity — nothing to do"
else
    awk -v a="$GitAlias" -v line="`$idline" '`$0 ~ "^[[:space:]]*Host[[:space:]]+" a "([[:space:]]|`$)" { print; print line; next } { print }' \
        "`$cfg" > "`$cfg.new" && mv "`$cfg.new" "`$cfg" && chmod 600 "`$cfg"
    echo "  ++  added $Identity to existing alias '$GitAlias'"
fi
"@
        # Two calls on purpose: `bash -s` consumes stdin, so the public key
        # cannot ride the same pipe as the script.
        $pub | ssh $Alias "cat > ~/.ssh/$Identity.pub" 2>&1 | Write-Host
        $remotePin | ssh $Alias "bash -s" 2>&1 | Write-Host
        Info "pin written. Verifying through the alias:"
        $pinnedId = (& ssh -o BatchMode=yes $Alias "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T $GitAlias 2>&1 | head -1" 2>$null | Select-Object -First 1)
        Write-Host "       $pinnedId"
        if ($pinnedId -and ($pinnedId -eq $laptopId)) {
            Info "the box now resolves to the intended identity"
        } else {
            Warn "the alias did not return the expected identity"
            Note "if $Key.pub is not registered at $GitHost yet, this is 'not registered', not"
            Note "'pin is wrong'. Register it and re-run. Otherwise, on the box:"
            Note "    bash scripts/host/diagnose-git-auth.sh"
        }
        Write-Host "  --  To use the pin, point the project's remote at the alias ON THE BOX:"
        Write-Host "        git remote set-url origin git@${GitAlias}:<group>/<project>.git"
        Write-Host "      Not done automatically: the project may not be cloned yet."
    } else {
        Note "skipped. Until the identity is fixed, pushes will be attributed to the wrong account."
    }
}

Step "Next: connect and provision the box"
Write-Host "  Connect (VSCode Remote-SSH -> $Alias, or: ssh $Alias), then ON THE BOX:"
Write-Host "      git clone https://github.com/Moon-Knight13/my_claude_dev"
Write-Host "      cd my_claude_dev && sudo bash scripts/host/provision-remote-box.sh --verify-cmd '<command>'"
Write-Host "  --verify-cmd is what proves the build tooling works; without it the run says so."
Write-Host "  If 'ssh-add -l' on the box says 'Error connecting to agent' AFTER a reconnect,"
Write-Host "  the socket is stale, not missing:  eval `"`$(bash scripts/host/fix-agent-sock.sh)`""
Write-Host "  Then 'make start' for the downstream build tooling (prompts for a password interactively; never stored)."
Info "local bootstrap complete"
