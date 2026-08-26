<#
.SYNOPSIS
    Windows bootstrap for connecting to a remote dev box (mirrors bootstrap-devbox.sh).
.DESCRIPTION
    Ensures OpenSSH agent is running, reuses/generates an ed25519 key, writes an
    idempotent ~/.ssh/config Host block (ForwardAgent yes), copies the public key
    to the box for passwordless login, installs the VSCode Remote-SSH extension,
    and sets remote.SSH.useExecServer=false.

    Prompts for per-dev values and the box login password LIVE — nothing secret is
    ever written into the repo.
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
    [string]$GitHost    = $env:DEVBOX_GIT_HOST,
    [string]$GitSshPort = $env:DEVBOX_GIT_SSH_PORT
)

$ErrorActionPreference = "Stop"
function Info($m) { Write-Host "  ++  $m" }
function Note($m) { Write-Host "  --  $m" }
function Warn($m) { Write-Warning $m }
function Step($m) { Write-Host ""; Write-Host ">> $m" }

$Key = Join-Path $HOME ".ssh\id_ed25519"

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
$BoxHost = "$HostPrefix$DevboxNum.$Domain"
$Alias   = "$HostPrefix$DevboxNum"
Info "Target: $BoxUser@$BoxHost"

# 2. SSH agent
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

# 3. SSH keypair
Step "SSH keypair"
if (Test-Path $Key) {
    Info "reusing existing key: $Key"
} else {
    Note "generating an ed25519 keypair (you will set a passphrase)"
    ssh-keygen -t ed25519 -C "$RangeUser" -f "$Key"
}
ssh-add "$Key" 2>$null | Out-Null

# 4. ~/.ssh/config Host block (idempotent)
Step "~/.ssh/config"
$sshDir = Join-Path $HOME ".ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$cfg = Join-Path $sshDir "config"
if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg | Out-Null }
if (Select-String -Path $cfg -Pattern "^\s*Host\s+$Alias(\s|$)" -Quiet) {
    Info "Host '$Alias' already in config — leaving as-is"
} else {
    Add-Content $cfg "`nHost $Alias $BoxHost`n    HostName $BoxHost`n    User $BoxUser`n    ForwardAgent yes`n    IdentityFile $Key"
    Info "added Host '$Alias' -> $BoxUser@$BoxHost (ForwardAgent yes)"
}

# 5. Copy public key (prompts for password once)
Step "Passwordless login"
Note "you'll be asked for your box login password ONCE (entered live, never stored)"
$pub = Get-Content "$Key.pub"
$remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
$pub | ssh "$BoxUser@$BoxHost" $remoteCmd
if ($LASTEXITCODE -eq 0) { Info "public key installed on $BoxHost" } else { Warn "key copy failed — add $Key.pub to authorized_keys manually" }

# 6. Local VSCode
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
} else {
    Note "VSCode 'code' CLI not on PATH — install Remote-SSH from the Marketplace and set remote.SSH.useExecServer=false"
}

# 7. GitLab + next steps
Step "GitLab key (one-time, manual)"
if (-not $GitHost) {
    $d = Read-Host "  ??  Git server hostname [git.$Domain]"
    $GitHost = if ($d) { $d } else { "git.$Domain" }
}
if (-not $GitSshPort) {
    $d = Read-Host "  ??  Git server SSH port [22]"
    $GitSshPort = if ($d) { $d } else { "22" }
}
Write-Host "  --  Add $Key.pub at https://$GitHost/-/user_settings/ssh_keys (that path is GitLab's; adjust for a different git server)"
Write-Host "      test: ssh -T git@$GitHost -p $GitSshPort"
Step "Next: connect and provision the box"
Write-Host "  Connect (VSCode Remote-SSH -> $Alias, or: ssh $Alias), then ON THE BOX:"
Write-Host "      git clone https://github.com/Moon-Knight13/my_claude_dev"
Write-Host "      cd my_claude_dev && sudo bash scripts/host/provision-remote-box.sh"
Write-Host "  Then 'make start' for the downstream build tooling (prompts for a password interactively; never stored)."
Info "local bootstrap complete"
