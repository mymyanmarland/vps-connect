<#
.SYNOPSIS
    connect-vps.ps1 - Connect to ANY VPS from PowerShell, with one command.
.DESCRIPTION
    PowerShell version of connect-vps.sh, for Windows users who live in
    PowerShell. It mirrors the Bash script, in order:
      1. Makes sure ssh and ssh-keygen are available (Windows 10/11
         built-in OpenSSH client).
      2. Reuses your existing ed25519 key, or generates one if missing.
         Only the public key (.pub) is ever copied to a VPS.
         A private key is never printed, copied, logged, or stored
         anywhere except the key file you already own in .ssh.
      3. Copies the public key to the VPS (first time only).
         If the VPS asks for a password at that prompt, you type it
         yourself, in your own PowerShell window, at that prompt. This
         script never asks for, stores, logs, or prints a password, and
         never puts a password in a file, an environment variable, or
         a command.
      4. Adds a short alias (Host block) to .ssh\config, backed up first.
         An existing Host block with the same name is replaced in place,
         never duplicated. All other Host entries are preserved.
      5. Tests the alias with: ssh <alias> 'echo VPS-CONNECT-OK'

    Windows OpenSSH has no ssh-copy-id, so the public key is copied with
    a plain ssh command. Only the first two tokens of the .pub file
    (key type + base64 body) are sent; any trailing comment is dropped,
    so the key cannot be mangled by shell quoting. The remote command
    is: mkdir -p ~/.ssh && printf '%s\n' '<type> <base64>' >>
    ~/.ssh/authorized_keys && chmod 700 ~/.ssh &&
    chmod 600 ~/.ssh/authorized_keys

    Requires: Windows 10/11 built-in OpenSSH client (ssh, ssh-keygen).
    If ssh is missing, enable it in Settings > Apps > Optional features >
    OpenSSH Client, or run (as Administrator):
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
    Run this script in PowerShell, not in CMD. The Bash version
    (connect-vps.sh) is for Git Bash, WSL, macOS, and Linux.

    Execution policy: if PowerShell blocks the script, do NOT change your
    system policy permanently first. Either unblock this one file:
        Unblock-File .\connect-vps.ps1
        .\connect-vps.ps1 -Name vps2 -Host <VPS-IP>
    or run it once without changing any policy:
        powershell -ExecutionPolicy Bypass -File .\connect-vps.ps1 -Name vps2 -Host <VPS-IP>
    A local script also runs under:
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    Note: a file downloaded with a web browser carries a "downloaded from
    the internet" mark, so it may still need Unblock-File even under
    RemoteSigned. A file downloaded with Invoke-WebRequest usually does
    not carry that mark.

.EXAMPLE
    .\connect-vps.ps1 -Name vps2 -Host <VPS-IP>
.EXAMPLE
    .\connect-vps.ps1 -Name vps2 -Host <VPS-IP> -User ubuntu -Port 2222
.EXAMPLE
    .\connect-vps.ps1 -DryRun -Name vps2 -Host <VPS-IP>
.EXAMPLE
    .\connect-vps.ps1
    # Interactive: prompts for alias, then IP.
.NOTES
    No dependencies beyond standard OpenSSH (ssh, ssh-keygen).
    Works because it uses $env:USERPROFILE\.ssh, never a hardcoded path.
#>
param(
    [string]$Name = "",
    [Alias("Host")][string]$HostName = "",
    [Alias("User")][string]$UserName = "root",
    [int]$Port = 22,
    [string]$Key = "",
    [switch]$DryRun,
    [switch]$Help
)

function Fail {
    param([string]$Message)
    Write-Error "Error: $Message"
    exit 1
}

if ($Help) {
    @"
Usage: .\connect-vps.ps1 [options]

Options:
  -Name NAME     Short alias, e.g. vps2 (letters, digits, - and _ only)
  -Host HOST     VPS IP address or hostname (required)
  -User USER     SSH user on the VPS (default: root)
  -Port PORT     SSH port (default: 22, range 1-65535)
  -Key PATH      Private key file (default: `$env:USERPROFILE\.ssh\id_ed25519)
  -DryRun        Print every step that would run; change nothing,
                 contact no VPS, generate no key
  -Help          Show this help and exit

Examples:
  .\connect-vps.ps1 -Name vps2 -Host <VPS-IP>
  .\connect-vps.ps1 -Name vps2 -Host <VPS-IP> -User ubuntu -Port 2222
  .\connect-vps.ps1 -DryRun -Name vps2 -Host <VPS-IP>
  .\connect-vps.ps1

Interactive mode: if -Name or -Host is missing, the script prompts for them.
The VPS password, if prompted by ssh on first copy, is typed only by you,
in your own PowerShell window, at that prompt.
"@
    exit 0
}

# --- Interactive prompts for missing required values -----------------------
if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = Read-Host "VPS alias (e.g. vps2)"
}
if ([string]::IsNullOrWhiteSpace($HostName)) {
    $HostName = Read-Host "VPS IP or hostname"
}
if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = "root" }
if ($Port -eq 0) { $Port = 22 }

# --- Validation (never run ssh with unvalidated input) ---------------------
if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
    Fail "Unsafe alias '$Name': use letters, digits, - and _ only"
}
$badHostChars = @(';', '&', '|', '$', '`', '"', "'", '\', '<', '>')
$badHost = $false
foreach ($c in $badHostChars) { if ($HostName.Contains($c)) { $badHost = $true } }
if ([string]::IsNullOrWhiteSpace($HostName) -or ($HostName -match '\s') -or $badHost) {
    Fail "Unsafe host: host must be a plain IP or hostname, no spaces or shell characters"
}
$badUser = $false
foreach ($c in $badHostChars) { if ($UserName.Contains($c)) { $badUser = $true } }
if ([string]::IsNullOrWhiteSpace($UserName) -or ($UserName -match '\s') -or $badUser) {
    Fail "Unsafe user: use a plain SSH username, no spaces or shell characters"
}
if ($Port -lt 1 -or $Port -gt 65535) {
    Fail "Port must be a number between 1 and 65535"
}

# --- Defaults and paths ------------------------------------------------------
$userProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $env:HOME }
if ([string]::IsNullOrWhiteSpace($userProfile)) { Fail "Could not determine your home folder (USERPROFILE/HOME is empty)" }
$sshDir = Join-Path $userProfile ".ssh"
if ([string]::IsNullOrWhiteSpace($Key)) {
    $Key = Join-Path $sshDir "id_ed25519"
} elseif ($Key -eq "~") {
    $Key = $userProfile
} elseif ($Key.StartsWith("~/") -or $Key.StartsWith("~\")) {
    $Key = Join-Path $userProfile $Key.Substring(2)
}
$configPath = Join-Path $sshDir "config"
$pubPath = "$Key.pub"
$keyForConfig = $Key -replace '\\', '/'

# --- Tool checks -------------------------------------------------------------
$missing = @()
foreach ($tool in @("ssh", "ssh-keygen")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
}
if ($missing.Count -gt 0) {
    Write-Error "Error: missing required tool(s): $($missing -join ' ')"
    Write-Error "Install hint:"
    Write-Error "  Windows: Settings > Apps > Optional features > OpenSSH Client,"
    Write-Error "           or (as Administrator): Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    Write-Error "This script does not install anything automatically."
    exit 1
}

# --- Dry run: print everything, change nothing -------------------------------
if ($DryRun) {
    Write-Host "Dry run - nothing will be changed, no VPS will be contacted."
    if (Test-Path $Key) {
        Write-Host "Step 1 - Key: reuse existing key $Key (no new key)"
    } else {
        Write-Host "Step 1 - Key: generate ed25519 key $Key with ssh-keygen"
        Write-Host "         (you would be prompted for a passphrase; empty means no passphrase prompt on connect)"
    }
    Write-Host "Step 2 - SSH directory: ensure $sshDir exists"
    if (Test-Path $configPath) {
        Write-Host "Step 3 - Config backup: copy $configPath to $configPath.bak-<date>-<pid> before editing"
    } else {
        Write-Host "Step 3 - Config backup: no existing $configPath, no backup needed"
    }
    Write-Host "Step 4 - Copy public key (no ssh-copy-id on Windows): ssh -p $Port ${UserName}@${HostName} 'mkdir -p ~/.ssh && printf <type> <base64> >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'"
    Write-Host "         (only the first two tokens of the .pub file are sent; any comment is dropped so quoting cannot mangle the key)"
    Write-Host "         (if the VPS asks for a password, you type it in your own PowerShell window at that prompt; it is never stored or printed)"
    Write-Host "Step 5 - Config block to add (replacing any existing Host $Name block, preserving all others):"
    Write-Host "  Host $Name"
    Write-Host "    HostName $HostName"
    Write-Host "    User $UserName"
    Write-Host "    Port $Port"
    Write-Host "    IdentityFile $keyForConfig"
    Write-Host "Step 6 - Test: ssh -o ConnectTimeout=10 -p $Port $Name 'echo VPS-CONNECT-OK'"
    Write-Host "After that, connect any time with: ssh $Name"
    exit 0
}

# --- Real run ---------------------------------------------------------------
Write-Host "VPS alias: $Name"
Write-Host "VPS host:  $HostName (user $UserName, port $Port)"

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

# Key: reuse if present, generate if missing. Never overwrite.
if (Test-Path $Key) {
    Write-Host "Key: reusing existing key $Key (not overwritten)"
} else {
    Write-Host "Key: generating ed25519 key $Key"
    Write-Host "You will be prompted for a passphrase. Empty means no passphrase prompt on connect."
    & ssh-keygen -t ed25519 -f $Key
    if ($LASTEXITCODE -ne 0) { Fail "ssh-keygen failed" }
}
if (-not (Test-Path $pubPath)) {
    Fail "Public key not found: $pubPath"
}

# Backup existing config before editing it.
if (Test-Path $configPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$configPath.bak-$stamp-$PID"
    Copy-Item -Path $configPath -Destination $backup -Force
    Write-Host "Config backup: $backup"
}

# Copy the public key to the VPS. Only the .pub file is sent.
Write-Host "Copying public key to ${UserName}@${HostName} (first time only)..."
Write-Host "If the VPS asks for a password, type it in your own PowerShell window at that prompt. It is never stored or printed by this script."
$pubContent = (Get-Content -Path $pubPath -Raw).Trim()
$pubTokens = ($pubContent -split '\s+')
if ($pubTokens.Count -lt 2) {
    Fail "Public key file is malformed (expected '<type> <base64>'): $pubPath"
}
$keyBody = "$($pubTokens[0]) $($pubTokens[1])"
$remoteCmd = "mkdir -p ~/.ssh && printf '%s\n' '$keyBody' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
& ssh -p $Port "$UserName@$HostName" $remoteCmd
if ($LASTEXITCODE -ne 0) {
    Fail "Key copy failed. Likely causes: wrong IP/host, wrong user, or the password was not accepted on first copy. No config change was made yet (a backup was taken before the copy)."
}
Write-Host "Public key copied."

# Add/replace the Host block, preserving all other entries.
$newLines = @()
if (Test-Path $configPath) {
    $existing = [System.IO.File]::ReadAllLines($configPath)
    $skip = $false
    foreach ($line in $existing) {
        if ($line -match '^\s*Host\s+') {
            $tokens = ($line.Trim() -split '\s+')
            $skip = $false
            for ($i = 1; $i -lt $tokens.Count; $i++) {
                if ($tokens[$i] -eq $Name) { $skip = $true }
            }
            if ($skip) { continue }
        }
        if ($skip) { continue }
        $newLines += $line
    }
    [System.IO.File]::WriteAllLines($configPath, $newLines)
} else {
    [System.IO.File]::WriteAllText($configPath, "")
}
$block = @("", "Host $Name", "    HostName $HostName", "    User $UserName", "    Port $Port", "    IdentityFile $keyForConfig")
Add-Content -Path $configPath -Value $block -Encoding Ascii
Write-Host "Alias added: ssh $Name"

# Test the alias.
Write-Host "Testing alias (ssh $Name)..."
& ssh -o ConnectTimeout=10 -p $Port $Name 'echo VPS-CONNECT-OK'
if ($LASTEXITCODE -eq 0) {
    Write-Host "Success: connected to $HostName via alias $Name."
    Write-Host "Connect any time with: ssh $Name"
    exit 0
} else {
    Write-Error "Test failed: could not connect via alias $Name."
    Write-Error "Likely causes: wrong IP/host, wrong user, wrong port, or the key is not in ~/.ssh/authorized_keys on the VPS."
    Write-Error "The alias was still added to $configPath, so fix the VPS side and run: ssh $Name"
    exit 1
}
