<#
.SYNOPSIS
    Descarga e instala PowerShell 7.5.0 para Windows desde el release oficial de
    GitHub.

.DESCRIPTION
    Descarga el .msi correspondiente a la arquitectura elegida en %TEMP% (si el archivo
    ya está descargado, lo reutiliza), lo instala con msiexec y borra el instalador al
    terminar.

    En modo silencioso genera un log con marca de tiempo en %TEMP% y, si la instalación
    falla, lo recorre buscando las líneas con "Error", "failed" o "fatal" y las imprime,
    para no tener que abrir el log a mano.

    La versión 7.5.0 está fijada en el script: para instalar otra hay que cambiar la
    URL y el nombre del archivo en las variables $Url y $Version.

    Requiere ejecutarse como administrador.

.PARAMETER architecture
    Arquitectura del paquete: "x" para x64 (valor por defecto) o "arm" para arm64.

.PARAMETER silent
    Con $true (valor por defecto) instala sin interfaz, sin reiniciar y con log. Con
    $false muestra el asistente del MSI.

.EXAMPLE
    .\InstallPowerShell_V_7.5.0_FinalVersion.ps1

    Instala PowerShell 7.5.0 x64 en modo silencioso.

.EXAMPLE
    .\InstallPowerShell_V_7.5.0_FinalVersion.ps1 -architecture 'arm' -silent $false

    Instala la versión arm64 mostrando el asistente.
#>
param (
    [string]$architecture = "x",  # Arquitectura por defecto puede ser "arm" la otra opcion
    [bool]$silent = $true                # Opción para instalación silenciosa
)

function Verify-IsFileExist {
    # Verificar si el archivo ya existe
    if (Test-Path $localFilePath) {
        Write-Host "El archivo ya existe en: $localFilePath"
    } else {
        # Descargar el archivo .msi
        Write-Host "Iniciando la descarga de PowerShell desde: $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localFilePath

        # Verificar si la descarga fue exitosa
        if (Test-Path $localFilePath) {
            Write-Host "El archivo se ha descargado correctamente: $localFilePath"
        } else {
            Write-Host "Error: No se pudo descargar el archivo."
            exit
        }
    }
}


function Install-Msi {
    param (
        [string]$installArgs
    )
    # Instalar el archivo .msi
    try {
        Write-Host "Iniciando la instalación de PowerShell..."
        # Ejecutar el proceso y redirigir la salida
        $process = Start-Process msiexec.exe -ArgumentList $installArgs -PassThru -Wait

        # Verificar el código de salida
        if ($process.ExitCode -eq 0) {
            Write-Host "La instalación se completó con éxito."
        } else {
            Write-Host "La instalación falló con el código de salida: $($process.ExitCode)"
            
            # Revisar el archivo de log para buscar errores
            if (Test-Path $logFilePath) {
                $logContent = Get-Content $logFilePath
                $errorLines = $logContent | Select-String -Pattern "Error|failed|fatal"  # Buscar líneas que contengan "Error", "failed" o "fatal"
                
                if ($errorLines) {
                    Write-Host "Se encontraron errores en el archivo de registro:"
                    $errorLines | ForEach-Object { Write-Host $_ }
                } else {
                    Write-Host "No se encontraron errores específicos en el archivo de registro."
                }
            } else {
                Write-Host "No se pudo encontrar el archivo de registro."
            }
        }
    } catch {
        Write-Host "Ocurrió un error durante la instalación: $_"
    } finally {
        # Limpiar el archivo descargado
        if (Test-Path $localFilePath) {
            Remove-Item $localFilePath -Force
            Write-Host "El archivo descargado ha sido eliminado."
        }
    }        
}

# Construcción URL
$Url = "https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/"
$Version = "PowerShell-7.5.0-win-$($architecture.ToLower())64.msi"

$fileName = $Version
# Concatenar la Url con el Nombre del archivo 
$downloadUrl = "$Url$fileName"
# Construcción URL
$downloadPath = "$env:TEMP"  # Ruta de descarga

# Nombre del archivo descargado con la ruta de descarga
$localFilePath = Join-Path -Path $downloadPath -ChildPath $fileName  # Combina la ruta y el nombre del archivo

#Invocar funcion si el archivo existe
Verify-IsFileExist

# Generar un nombre de archivo de log con fecha y hora
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFilePath = "$env:TEMP\install_log_$timestamp.txt"

# Construir los argumentos de instalación
if ($silent) {
    $installArgs = "/i `"$localFilePath`" /quiet /norestart /log `"$logFilePath`""
} else {
    $installArgs = "/i `"$localFilePath`" /norestart"
}

# Invocar metodo Install-Msi que contiene la funcionalidad para Instalar el archivo .msi
Install-Msi -installArgs $installArgs