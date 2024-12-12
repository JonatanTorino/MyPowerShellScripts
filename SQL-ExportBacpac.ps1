
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$BackupDirectory = "J:\MSSQL_BACKUPTEMP",

    [Parameter(Mandatory=$false)]
    [string]$NewDatabaseName = "AxDB_Backup",

    [Parameter(Mandatory=$false)]
    [string]$TargetPath = "J:\MSSQL_BACKUP",

    [Parameter(Mandatory=$false)]
    [string]$ExtraDescription = ""
)

function Write-StatusMessage {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

try {
    # Verificar y crear directorios necesarios
    foreach ($path in @($TargetPath, $BackupDirectory)) {
        if (-not (Test-Path $path)) {
            Write-StatusMessage "Creando directorio: $path"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    # Generar nombre del archivo BACPAC
    $bacpacFileName = "$NewDatabaseName-$env:computername-$(Get-Date -format 'yyyyMMdd-HHmm')"
    if (-not [string]::IsNullOrEmpty($ExtraDescription)) {
        $bacpacFileName += "_$($ExtraDescription.Replace(' ', ''))"
    }
    $bacpacFileName += ".bacpac"
    $BacpacFile = Join-Path $TargetPath $bacpacFileName

    # Mostrar información de la operación
    Write-StatusMessage "Información de la operación"
    Write-Host "Directorio de backup: $TargetPath"
    Write-Host "Nombre de base de datos: $NewDatabaseName"
    Write-Host "Archivo BACPAC: $BacpacFile"

    # Generar el archivo BACPAC
    Write-StatusMessage "Generando archivo BACPAC $BacpacFile"
    New-D365Bacpac -ExportModeTier1 `
                   -BackupDirectory $BackupDirectory `
                   -NewDatabaseName $NewDatabaseName `
                   -BacpacFile $BacpacFile `
                   -ShowOriginalProgress

    if (Test-Path $BacpacFile) {
        Write-StatusMessage "Archivo $BacpacFile generado exitosamente"
        $fileInfo = Get-Item $BacpacFile
        Write-Host "Tamaño del archivo: $([math]::Round($fileInfo.Length / 1GB, 2)) GB"
    }
    else {
        throw "No se pudo generar el archivo $BacpacFile"
    }
}
catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "El proceso no se completó correctamente" -ForegroundColor Red
}
finally {
    # Limpiar directorio temporal si existe
    if (Test-Path $BackupDirectory) {
        Write-StatusMessage "Limpiando directorio temporal"
        Remove-Item -Path $BackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}