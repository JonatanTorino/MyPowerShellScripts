# =============================================
# Script: Actualizador DDNS No-IP con PowerShell
# Autor: Jonatan (ajustado por ChatGPT)
# =============================================

# Configuración
$CredPath = "$env:USERPROFILE\noip_cred.xml"
$LogPath  = "$env:USERPROFILE\noip_update.log"
$LastIPFile = "$env:USERPROFILE\noip_lastip.txt"
$HostName = "vpnjonatote.zapto.org"

# --- Obtener credenciales (crear si no existen)
if (!(Test-Path $CredPath)) {
    Write-Host "No se encontraron credenciales guardadas. Ingrese las de No-IP."
    Get-Credential -Message "Ingrese sus credenciales de No-IP" | Export-Clixml -Path $CredPath
    Write-Host "Credenciales guardadas en $CredPath"
}
$Cred = Import-Clixml -Path $CredPath

# --- Obtener IP pública
try {
    $PublicIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
    Write-Host "IP pública detectada: $PublicIP"
} catch {
    Write-Error "No se pudo obtener la IP pública."
    exit 1
}

# --- Verificar si la IP cambió
$DoUpdate = $true
if (Test-Path $LastIPFile) {
    $LastIP = Get-Content $LastIPFile -Raw
    if ($LastIP -eq $PublicIP) {
        Write-Host "La IP no cambió ($PublicIP). No se realiza actualización."
        $DoUpdate = $false
    }
}

if ($DoUpdate) {
    # --- Construir cabecera de autenticación
    $User = $Cred.UserName
    $Pass = $Cred.GetNetworkCredential().Password
    $AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$User`:$Pass"))
    $Headers = @{ Authorization = "Basic $AuthInfo" }

    # --- Construir URL de update
    $UpdateUrl = "https://dynupdate.no-ip.com/nic/update?hostname=$HostName&myip=$PublicIP"

    # --- Ejecutar actualización
    try {
        $Response = Invoke-RestMethod -Uri $UpdateUrl -Headers $Headers -Method Get
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogLine = "$Timestamp - IP: $PublicIP - Respuesta: $Response"
        Add-Content -Path $LogPath -Value $LogLine
        Set-Content -Path $LastIPFile -Value $PublicIP
        Write-Host "Actualización completada. Respuesta: $Response"
    } catch {
        Write-Error "Error al actualizar el dominio: $_"
    }
}
