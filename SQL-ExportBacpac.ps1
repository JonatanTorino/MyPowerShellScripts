
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
    Write-Information "`n=== $Message ===" -InformationAction Continue
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
    Write-Information "Directorio de backup: $TargetPath" -InformationAction Continue
    Write-Information "Nombre de base de datos: $NewDatabaseName" -InformationAction Continue
    Write-Information "Archivo BACPAC: $BacpacFile" -InformationAction Continue

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
        Write-Information "Tamaño del archivo: $([math]::Round($fileInfo.Length / 1GB, 2)) GB" -InformationAction Continue
    }
    else {
        throw "No se pudo generar el archivo $BacpacFile"
    }
}
catch {
    Write-Error "`nError: $($_.Exception.Message)"
    Write-Error "El proceso no se completó correctamente"
}
finally {
    # Limpiar directorio temporal si existe
    if (Test-Path $BackupDirectory) {
        Write-StatusMessage "Limpiando directorio temporal"
        Remove-Item -Path $BackupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}