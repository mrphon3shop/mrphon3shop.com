# connect-node.ps1 - one command to reach the mrphon3shop node from Windows.
#
# It does the three things Windows ssh gets wrong when you do them by hand:
#   1. locks the private key down (Windows OpenSSH refuses a key others can read)
#   2. picks the right door: the tailnet if Tailscale is running, otherwise the
#      public Funnel door with a TLS wrapper (openssl if present, otherwise a
#      built-in .NET tunnel it installs for you - no dependencies, no admin)
#   3. connects with sane options (host key accepted once, key-only)
#
# Usage
#   .\connect-node.ps1                                     # interactive shell
#   .\connect-node.ps1 -RemoteCommand 'node-status'        # run one command
#   .\connect-node.ps1 -Key C:\keys\mrphon3shop-node_ed25519 -ForcePublicDoor
#
[CmdletBinding()]
param(
    [string]$Key = "",
    [string]$NodeHost = "mrphon3shop-node.tail3641f4.ts.net",
    [string]$UserName = "root",
    [int]$PublicPort = 10000,
    [switch]$ForcePublicDoor,
    [switch]$Diagnose,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemoteCommand
)

$ErrorActionPreference = "Stop"
function Say($m) { Write-Host "[connect] $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. the key --
$candidates = @()
if ($Key) { $candidates += $Key }
$candidates += @(
    "$env:USERPROFILE\.ssh\mrphon3shop-node_ed25519",
    "C:\keys\mrphon3shop-node_ed25519",
    "$env:USERPROFILE\Downloads\mrphon3shop-node_ed25519"
)
$KeyFile = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $KeyFile) {
    Write-Host "private key not found. Put mrphon3shop-node_ed25519 in C:\keys\ and retry, or pass -Key <path>." -ForegroundColor Red
    exit 1
}
Say "key: $KeyFile"

# Windows OpenSSH refuses a key that other accounts can read, so make this file
# owned by, and readable only by, the current user.
$me = "$env:USERDOMAIN\$env:USERNAME"
& icacls $KeyFile /inheritance:r 2>&1 | Out-Null
& takeown /f $KeyFile 2>&1 | Out-Null
foreach ($who in @("NT AUTHORITY\Authenticated Users", "BUILTIN\Users", "Everyone", "NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
    & icacls $KeyFile /remove:g $who 2>$null | Out-Null
}
& icacls $KeyFile /grant:r "${me}:(R)" 2>&1 | Out-Null
$acl = (& icacls $KeyFile) -join " "
Say ("acl: " + ($acl -replace '\s+', ' ').Trim())

$sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshCmd) { Write-Host "Windows OpenSSH client not found (Settings > Apps > Optional features > OpenSSH Client)." -ForegroundColor Red; exit 1 }

# --------------------------------------------------------- 2. which door? -----
$tailnetUp = $false
if (-not $ForcePublicDoor) {
    $ts = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($ts) {
        try {
            $st = (& tailscale.exe status --json 2>$null | ConvertFrom-Json)
            if ($st.BackendState -eq "Running") { $tailnetUp = $true }
        } catch { }
    }
}

if ($tailnetUp) {
    Say "door: tailnet (Tailscale is connected) - plain ssh, no wrapper"
    $sshArgs = @(
        "-i", $KeyFile, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=25", "$UserName@$NodeHost"
    )
} else {
    Say "door: public Funnel (TLS) on port $PublicPort"
    $openssl = (Get-Command openssl.exe -ErrorAction SilentlyContinue).Source
    if (-not $openssl) {
        foreach ($p in @(
                "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
                "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe",
                "C:\Program Files\Git\usr\bin\openssl.exe")) {
            if (Test-Path $p) { $openssl = $p; break }
        }
    }
    if ($openssl) {
        Say "tls wrapper: $openssl"
        $proxy = "$openssl s_client -4 -quiet -connect %h:%p -servername %h"
    } else {
        Say "tls wrapper: built-in .NET tunnel (no openssl on this machine)"
        $tunnel = "$env:USERPROFILE\.ssh\tls-tunnel.ps1"
        if (-not (Test-Path $tunnel)) {
            New-Item -ItemType Directory -Force (Split-Path $tunnel) | Out-Null
            $tunnelCode = @'
param([Parameter(Mandatory=$true)][string]$TargetHost, [Parameter(Mandatory=$true)][int]$TargetPort)
$ErrorActionPreference = "Stop"
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($TargetHost, $TargetPort)
$ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, ({ $true }))
$ssl.AuthenticateAsClient($TargetHost)
$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()
$pump = $ssl.CopyToAsync($stdout)
$buf = New-Object byte[] 32768
while (($n = $stdin.Read($buf, 0, $buf.Length)) -gt 0) { $ssl.Write($buf, 0, $n); $ssl.Flush() }
try { $pump.Wait(3000) | Out-Null } catch { }
$ssl.Dispose(); $client.Close()
'@
            Set-Content -Path $tunnel -Value $tunnelCode -Encoding ASCII
            Say "installed $tunnel"
        }
        $proxy = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$tunnel`" %h %p"
    }
    $sshArgs = @(
        "-i", $KeyFile, "-p", "$PublicPort",
        "-o", "ProxyCommand=$proxy",
        "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=25", "$UserName@$NodeHost"
    )
}

if ($Diagnose) {
    Say ("ssh command: ssh " + ($sshArgs -join " "))
    if ($RemoteCommand) { Say ("remote: " + ($RemoteCommand -join " ")) }
    exit 0
}

# ------------------------------------------------------------- 3. connect -----
Say "connecting..."
& ssh.exe @sshArgs @RemoteCommand
exit $LASTEXITCODE
