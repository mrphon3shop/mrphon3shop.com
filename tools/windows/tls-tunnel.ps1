# tls-tunnel.ps1 — dependency-free TLS wrapper for ssh ProxyCommand on Windows.
#
# Tailscale Funnel relays demultiplex incoming connections by the TLS SNI, so
# anything reaching the public door has to start with a TLS handshake. Windows'
# built-in ssh.exe cannot do that, so this script opens the TLS connection and
# bridges it to stdin/stdout; ssh then speaks plain SSH inside the tunnel.
#
# Usage (PowerShell):
#   ssh -p 10000 -i C:\keys\mrphon3shop-node_ed25519 `
#       -o "ProxyCommand=powershell -NoProfile -ExecutionPolicy Bypass -File C:\keys\tls-tunnel.ps1 %h %p" `
#       root@mrphon3shop-node.tail3641f4.ts.net
#
# Put it in .ssh/config instead and the command becomes just `ssh node`:
#   Host node
#       HostName mrphon3shop-node.tail3641f4.ts.net
#       Port 10000
#       User root
#       IdentityFile C:\keys\mrphon3shop-node_ed25519
#       ProxyCommand powershell -NoProfile -ExecutionPolicy Bypass -File C:\keys\tls-tunnel.ps1 %h %p

param(
    [Parameter(Mandatory = $true)][string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$TargetPort
)

$ErrorActionPreference = 'Stop'

$client = New-Object System.Net.Sockets.TcpClient
$client.NoDelay = $true
$client.Connect($TargetHost, $TargetPort)

$ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient($TargetHost)      # SNI = the funnel name; the relay routes on it

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

# node -> client
$pump = $ssl.CopyToAsync($stdout)

# client -> node
$buffer = New-Object byte[] 32768
try {
    while (($read = $stdin.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $ssl.Write($buffer, 0, $read)
        $ssl.Flush()
    }
} catch { }   # client closed the stream: normal end of session
try { $pump.Wait(3000) | Out-Null } catch { }
$ssl.Dispose()
$client.Close()
