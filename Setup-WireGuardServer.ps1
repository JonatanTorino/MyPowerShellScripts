param(
    [string]$ClientName = "client1",
    [string]$ClientIP   = ""
)

Write-Host "=== Instalación y configuración de WireGuard con cliente y QR ==="

# --- Instalar WireGuard ---
if (-not (Get-Command "C:\Program Files\WireGuard\wireguard.exe" -ErrorAction SilentlyContinue)) {
    choco install wireguard -y
    Write-Host "WireGuard instalado."
} else {
    Write-Host "WireGuard ya está instalado."
}

# --- Detectar subred disponible ---
function Get-AvailableSubnet {
    $usedRoutes = Get-NetRoute | Select-Object -ExpandProperty DestinationPrefix
    $candidateSubnets = @("10.7.0.0/24","10.13.37.0/24","172.20.0.0/24","192.168.77.0/24","10.44.0.0/24")
    
    foreach ($subnet in $candidateSubnets) {
        $base = $subnet.Split("/")[0]
        if ($usedRoutes -notcontains $subnet -and ($usedRoutes -notmatch $base)) {
            return $subnet
        }
    }
    throw "No se encontró un rango libre. Revisá manualmente."
}

Write-Host "=== Detectando subred disponible ==="
$chosenSubnet = Get-AvailableSubnet
$base = $chosenSubnet.Split("/")[0].Split(".")[0..2] -join "."
$serverIP = "$base.1/24"

if ([string]::IsNullOrWhiteSpace($ClientIP)) {
    $ClientIP = "$base.2/32"
}

Write-Host "Subred elegida: $chosenSubnet"
Write-Host "IP servidor: $serverIP"
Write-Host "IP cliente ($ClientName): $ClientIP"

# --- Generar claves ---
$wgPath = "C:\Program Files\WireGuard\wg.exe"
Write-Host "=== Generando claves ==="

$serverPriv = & $wgPath genkey
$serverPub = $serverPriv | & $wgPath pubkey
$clientPriv = & $wgPath genkey
$clientPub = $clientPriv | & $wgPath pubkey

Write-Host "`nServidor - Pública: $serverPub"
Write-Host "Cliente $ClientName - Pública: $clientPub`n"

# --- Crear carpeta config ---
$configDir = "C:\Program Files\WireGuard\Config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }

# --- Crear archivo servidor ---
$serverConfig = Join-Path $configDir "wg0.conf"
@"
[Interface]
PrivateKey = $serverPriv
Address = $serverIP
ListenPort = 51820

[Peer]
PublicKey = $clientPub
AllowedIPs = $ClientIP
"@ | Out-File -FilePath $serverConfig -Encoding ASCII

Write-Host "Archivo del servidor creado en: $serverConfig"

# --- Preguntar dominio/IP ---
$endpoint = Read-Host "Ingresa el dominio o IP pública del servidor"

# --- Crear archivo cliente ---
$clientConfig = Join-Path $configDir "$ClientName.conf"
@"
[Interface]
PrivateKey = $clientPriv
Address = $ClientIP
DNS = 1.1.1.1

[Peer]
PublicKey = $serverPub
Endpoint = $endpoint:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"@ | Out-File -FilePath $clientConfig -Encoding ASCII

Write-Host "Archivo del cliente creado en: $clientConfig"

# --- Generar QR usando API goqr.me ---
$clientConfigText = Get-Content $clientConfig -Raw
$encodedConfig = [System.Web.HttpUtility]::UrlEncode($clientConfigText)
$qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=$encodedConfig"

$qrFile = Join-Path $configDir "$ClientName-qr.png"
Invoke-WebRequest -Uri $qrUrl -OutFile $qrFile

Write-Host "QR generado en: $qrFile"
Write-Host "Escanealo desde la app WireGuard en tu celular."
