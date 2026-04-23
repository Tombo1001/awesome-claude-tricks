#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up SSH access from Windows into WSL2 so Claude Code can read Docker Compose logs directly.

.DESCRIPTION
    Automates the full setup described at: https://yourblog.com/claude-code-wsl2-docker-logs
    - Generates an ed25519 SSH key on Windows (if one doesn't already exist)
    - Installs and configures OpenSSH server in WSL2 Ubuntu
    - Copies the public key into WSL2 authorized_keys
    - Adds a passwordless sudo rule for the SSH service
    - Configures auto-start of SSH when WSL2 launches
    - Adds a named 'wsl2' host to your Windows SSH config

.PARAMETER DistroName
    The WSL2 distro to configure. Defaults to your default WSL distro.
    Run 'wsl --list' to see available distros.

.PARAMETER SshPort
    Port for the WSL2 SSH server. Defaults to 2222 to avoid conflict with Windows OpenSSH on port 22.

.PARAMETER KeyName
    Name of the SSH key file to create under ~/.ssh/. Defaults to 'id_ed25519_wsl2'.

.PARAMETER Force
    Re-run configuration steps even if they appear to already be in place.

.EXAMPLE
    .\setup-claude-wsl2-ssh.ps1

.EXAMPLE
    .\setup-claude-wsl2-ssh.ps1 -DistroName "Ubuntu-22.04" -SshPort 2223

.NOTES
    Run this from a standard PowerShell terminal (not WSL).
    Administrator rights are NOT required.
#>

param(
    [string]$DistroName = "",
    [int]$SshPort = 2222,
    [string]$KeyName = "id_ed25519_wsl2",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "    [--] $Message (already configured, skipping)" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [!!] $Message" -ForegroundColor Yellow
}

function Invoke-Wsl {
    <#
    Runs a command inside WSL2 and returns stdout as a string.
    Throws if the exit code is non-zero.
    #>
    param(
        [string]$Command,
        [string]$Distro = $script:DistroName
    )
    $args = @("--distribution", $Distro, "--", "bash", "-c", $Command)
    $output = & wsl @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command`nOutput: $output"
    }
    return ($output | Out-String).Trim()
}

function Invoke-WslRoot {
    # Runs a command as root inside WSL2 without needing sudo or a password.
    # Uses 'wsl -u root' which WSL2 supports natively from the Windows side.
    param(
        [string]$Command,
        [string]$Distro = $script:DistroName
    )
    $wslArgs = @("--distribution", $Distro, "--user", "root", "--", "bash", "-c", $Command)
    $output = & wsl @wslArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL root command failed (exit $LASTEXITCODE): $Command`nOutput: $output"
    }
    return ($output | Out-String).Trim()
}

# ---------------------------------------------------------------------------
# 0. Preflight checks
# ---------------------------------------------------------------------------

Write-Step "Preflight checks"

# Check WSL is available
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw "WSL is not installed or not in PATH. Install WSL2 first: https://learn.microsoft.com/en-us/windows/wsl/install"
}

# Resolve distro name
if ($DistroName -eq "") {
    # Get the default distro (marked with (Default) in wsl --list output)
    $wslList = & wsl --list --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "No WSL2 distros found. Install Ubuntu from the Microsoft Store first."
    }
    # wsl --list --quiet outputs distro names, first non-empty line is the default
    $lines = $wslList | Where-Object { $_ -match '\S' }
    if ($lines.Count -eq 0) {
        throw "No WSL2 distros found."
    }
    # --quiet lists default first
    $DistroName = ($lines[0] -replace '\x00', '').Trim()
    Write-OK "Using default WSL2 distro: $DistroName"
} else {
    Write-OK "Using specified WSL2 distro: $DistroName"
}

# Check SSH client is available on Windows (for key generation and final test)
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "OpenSSH client not found on Windows. Enable it via: Settings > Optional Features > OpenSSH Client"
}
Write-OK "OpenSSH client available on Windows"

# Get WSL2 username
$WslUser = Invoke-Wsl "whoami"
Write-OK "WSL2 user: $WslUser"

# ---------------------------------------------------------------------------
# 1. Generate SSH key on Windows
# ---------------------------------------------------------------------------

Write-Step "SSH key setup"

$sshDir = Join-Path $env:USERPROFILE ".ssh"
$keyPath = Join-Path $sshDir $KeyName
$pubKeyPath = "$keyPath.pub"

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-OK "Created $sshDir"
}

if ((Test-Path $keyPath) -and -not $Force) {
    Write-Skip "SSH key already exists at $keyPath"
} else {
    if (Test-Path $keyPath) { Remove-Item $keyPath, $pubKeyPath -Force }
    & ssh-keygen -t ed25519 -C "claude-code-wsl2" -f $keyPath -N '""'
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }
    Write-OK "Generated new SSH key: $keyPath"
}

$pubKey = Get-Content $pubKeyPath -Raw
$pubKey = $pubKey.Trim()
Write-OK "Public key loaded"

# ---------------------------------------------------------------------------
# 2. Install OpenSSH server in WSL2
# ---------------------------------------------------------------------------

Write-Step "Installing OpenSSH server in WSL2"

$sshdInstalled = Invoke-Wsl "dpkg -l openssh-server 2>/dev/null | grep -c '^ii' || true"
if ($sshdInstalled -eq "1" -and -not $Force) {
    Write-Skip "openssh-server already installed"
} else {
    Write-Host "    Running apt update and install (this may take a moment)..." -ForegroundColor DarkGray
    Invoke-WslRoot "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
    Invoke-WslRoot "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server"
    Write-OK "openssh-server installed"
}

# ---------------------------------------------------------------------------
# 3. Configure sshd
# ---------------------------------------------------------------------------

Write-Step "Configuring SSH daemon in WSL2"

$sshdConfig = @"
# Managed by setup-claude-wsl2-ssh.ps1
Port $SshPort
ListenAddress 0.0.0.0
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
"@

# Escape for bash heredoc
$escapedConfig = $sshdConfig -replace "'", "'\\'''"
Invoke-WslRoot "printf '%s\n' '$escapedConfig' > /etc/ssh/sshd_config"
Write-OK "sshd_config written (port $SshPort, pubkey only)"

# Regenerate host keys if they don't exist (fresh installs sometimes skip this)
Invoke-WslRoot "ssh-keygen -A 2>/dev/null || true"
Write-OK "SSH host keys present"

# ---------------------------------------------------------------------------
# 4. Authorise the Windows public key in WSL2
# ---------------------------------------------------------------------------

Write-Step "Authorising Windows SSH key in WSL2"

$wslSshDir = Invoke-Wsl "echo ~/.ssh"
Invoke-Wsl "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

# Check if key is already in authorized_keys
$alreadyAuthorised = Invoke-Wsl "grep -qF '$pubKey' ~/.ssh/authorized_keys 2>/dev/null && echo yes || echo no"
if ($alreadyAuthorised -eq "yes" -and -not $Force) {
    Write-Skip "Public key already in authorized_keys"
} else {
    # Append (or create)
    Invoke-Wsl "echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    # Deduplicate in case we just added a duplicate
    Invoke-Wsl "sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
    Write-OK "Public key added to ~/.ssh/authorized_keys"
}

# ---------------------------------------------------------------------------
# 5. Passwordless sudo for SSH service management
# ---------------------------------------------------------------------------

Write-Step "Setting up passwordless sudo for SSH service"

# We use 'wsl -u root' for privileged operations throughout this script, so
# the SSH service auto-start in .bashrc also needs to work without a password.
# Write a sudoers drop-in so 'sudo service ssh start' works for the normal user.
$sudoersLine = "$WslUser ALL=(ALL) NOPASSWD: /usr/sbin/service ssh *"
$sudoersFile = "/etc/sudoers.d/claude-ssh"

$sudoersExists = Invoke-Wsl "test -f $sudoersFile && echo yes || echo no"
if ($sudoersExists -eq "yes" -and -not $Force) {
    Write-Skip "Sudoers entry already exists at $sudoersFile"
} else {
    Invoke-WslRoot "echo '$sudoersLine' > $sudoersFile && chmod 440 $sudoersFile"
    Write-OK "Sudoers entry created: $sudoersFile"
}

# ---------------------------------------------------------------------------
# 6. Auto-start SSH on WSL2 session open
# ---------------------------------------------------------------------------

Write-Step "Configuring SSH auto-start in WSL2"

$bashrcMarker = "# claude-wsl2-ssh-autostart"
$bashrcEntry = @"

$bashrcMarker
sudo service ssh start > /dev/null 2>&1
"@

$markerExists = Invoke-Wsl "grep -qF '$bashrcMarker' ~/.bashrc 2>/dev/null && echo yes || echo no"
if ($markerExists -eq "yes" -and -not $Force) {
    Write-Skip "Auto-start entry already in ~/.bashrc"
} else {
    # Remove old entry if Force
    if ($Force) {
        Invoke-Wsl "sed -i '/$bashrcMarker/,+1d' ~/.bashrc 2>/dev/null || true"
    }
    Invoke-Wsl "printf '%s\n' '$bashrcEntry' >> ~/.bashrc"
    Write-OK "SSH auto-start added to ~/.bashrc"
}

# Start the service now for this session
Invoke-WslRoot "service ssh start"
Write-OK "SSH service started"

# ---------------------------------------------------------------------------
# 7. Add 'wsl2' host entry to Windows SSH config
# ---------------------------------------------------------------------------

Write-Step "Configuring Windows SSH client"

$sshConfigPath = Join-Path $sshDir "config"
$hostBlock = @"

# Claude Code WSL2 access - managed by setup-claude-wsl2-ssh.ps1
Host wsl2
  HostName localhost
  Port $SshPort
  User $WslUser
  IdentityFile ~/.ssh/$KeyName
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
"@

if (-not (Test-Path $sshConfigPath)) {
    New-Item -ItemType File -Path $sshConfigPath -Force | Out-Null
}

$configContent = Get-Content $sshConfigPath -Raw -ErrorAction SilentlyContinue
if ($configContent -and $configContent -match "Host wsl2" -and -not $Force) {
    Write-Skip "'wsl2' host already in $sshConfigPath"
} else {
    if ($Force -and $configContent -match "Host wsl2") {
        # Remove old wsl2 block
        $configContent = $configContent -replace "(?s)\n# Claude Code WSL2.*?(?=\n# |\nHost |\z)", ""
        Set-Content $sshConfigPath $configContent
    }
    Add-Content $sshConfigPath $hostBlock
    Write-OK "Added 'wsl2' host to $sshConfigPath"
}

# ---------------------------------------------------------------------------
# 8. Smoke test
# ---------------------------------------------------------------------------

Write-Step "Testing SSH connection"

# Confirm sshd is actually listening before we attempt to connect
$sshdRunning = Invoke-WslRoot "service ssh status 2>&1 | grep -c 'is running' || true"
if ($sshdRunning -ne "1") {
    Write-Warn "sshd does not appear to be running. Trying to start it again..."
    Invoke-WslRoot "service ssh start"
    Start-Sleep -Seconds 2
} else {
    Write-OK "sshd is running on port $SshPort"
}

# Confirm the port is actually open from Windows
$portOpen = (Test-NetConnection -ComputerName localhost -Port $SshPort -WarningAction SilentlyContinue).TcpTestSucceeded
if (-not $portOpen) {
    Write-Warn "Port $SshPort is not reachable from Windows. WSL2 networking or firewall may be blocking it."
    Write-Warn "Try running 'ssh wsl2' manually after opening a WSL2 terminal (which triggers .bashrc auto-start)."
} else {
    Write-OK "Port $SshPort is reachable from Windows"

    try {
        $testResult = & ssh -i $keyPath -p $SshPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$WslUser@localhost" "echo connected && docker --version 2>/dev/null || echo 'docker not in PATH - run from WSL2 shell first'" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "SSH connection successful"
            Write-Host "    Output: $testResult" -ForegroundColor DarkGray
        } else {
            Write-Warn "SSH test returned exit code $LASTEXITCODE. Output: $testResult"
        }
    } catch {
        Write-Warn "SSH test threw an exception: $_"
    }

    # Friendly named alias test
    try {
        $namedTest = & ssh wsl2 "echo named-host-ok" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "'ssh wsl2' works via named host"
        } else {
            Write-Warn "'ssh wsl2' failed. Check $sshConfigPath"
        }
    } catch {
        Write-Warn "'ssh wsl2' test failed. Check your SSH config at $sshConfigPath"
    }
}

# ---------------------------------------------------------------------------
# 9. Print CLAUDE.md snippet
# ---------------------------------------------------------------------------

Write-Step "Setup complete"

$claudeMdSnippet = @'
## Docker / WSL2 Environment

- Docker and Docker Compose run inside WSL2, not on Windows directly.
- SSH access to WSL2 is available. Use `ssh wsl2` for all Docker operations.
- **Always check container logs proactively** - do not ask the user to paste them.

### Useful commands

Replace YOUR_PROJECT_PATH with the path to your project inside WSL2 (e.g. projects/myapp).

    # All service logs
    ssh wsl2 "docker compose -f ~/YOUR_PROJECT_PATH/docker-compose.yml logs --tail=100"

    # Single service logs
    ssh wsl2 "docker compose -f ~/YOUR_PROJECT_PATH/docker-compose.yml logs --tail=100 YOUR_SERVICE"

    # Container status
    ssh wsl2 "docker ps -a"

    # Restart a service
    ssh wsl2 "docker compose -f ~/YOUR_PROJECT_PATH/docker-compose.yml restart YOUR_SERVICE"
'@

Write-Host ""
Write-Host "---------------------------------------------------------------" -ForegroundColor White
Write-Host " Add the following to your CLAUDE.md to enable autonomous log " -ForegroundColor White
Write-Host " reading in Claude Code sessions:                              " -ForegroundColor White
Write-Host "---------------------------------------------------------------" -ForegroundColor White
Write-Host $claudeMdSnippet -ForegroundColor DarkCyan
Write-Host "---------------------------------------------------------------" -ForegroundColor White
Write-Host ""
Write-Host "  Quick test now:  ssh wsl2 ""docker ps""" -ForegroundColor White
Write-Host "  Blog post:       https://yourblog.com/claude-code-wsl2-docker-logs" -ForegroundColor White
Write-Host ""
