[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac
    #,
    # [Parameter(Mandatory=$true)]
    #[string]$urlDescargarBacpac
    ,
    [bool]$includeSwitch = $false
    ,
    [bool]$includeInstallSqlPackage = $false
    ,
    [bool]$skipBuildModels = $false
    #,
    #[switch]$reinstallCsu = $false
    ,
    [string[]]$tablesToClean
    ,
    [string[]]$tablesToExclude
    ,
    [string[]]$modelsToBuild
    ,
    [bool]$skipCheckGitRepoUpdated = $false
    ,
    [bool]$skipCleanTables = $false
    ,
    [int] $MaxParallelism = 8
)

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Information "Directorio del script: $ScriptDirectory" -InformationAction Continue

# Parsear tablesToClean
if (-not [string]::IsNullOrWhiteSpace($tablesToClean)) {
    $tablesToClean = $tablesToClean -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
    Write-Information "Tablas a limpiar: $($tablesToClean -join ', ')" -InformationAction Continue
} else {
    $tablesToClean = @()
}

# Parsear tablesToExclude
if (-not [string]::IsNullOrWhiteSpace($tablesToExclude)) {
    $tablesToExclude = $tablesToExclude -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
    Write-Information "Tablas a excluir: $($tablesToExclude -join ', ')" -InformationAction Continue
} else {
    $tablesToExclude = @()
}

# Parsear modelsToBuild
if (-not [string]::IsNullOrWhiteSpace($modelsToBuild)) {
    $modelsToBuild = $modelsToBuild -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
    Write-Information "Modelos a compilar: $($modelsToBuild -join ', ')" -InformationAction Continue
} else {
    $modelsToBuild = @()
}


function ImprimirTiempoTranscurrido {
    param (
        [string]$mensaje
    )
    
    # Calcula la diferencia de tiempo
    $horaActual = Get-Date
    $tiempoTranscurrido = $horaActual - $inicio
    # Imprime las marcas de tiempo y el tiempo transcurrido
    Write-Information  "$mensaje, Tiempo transcurrido : $tiempoTranscurrido" -InformationAction Continue
}

if (!$skipCheckGitRepoUpdated) {
    $checkGitScript = Join-Path $ScriptDirectory "CheckGitRepoUpdated.ps1"
    if (Test-Path $checkGitScript) {
        Write-Information "Ejecutando CheckGitRepoUpdated.ps1" -InformationAction Continue
        & $checkGitScript .
    } else {
        Write-Warning "No se encontró CheckGitRepoUpdated.ps1 en $checkGitScript"
    }
}

# Guarda la marca de tiempo de inicio
$inicio = Get-Date
Write-Information "Inicio: $inicio" -InformationAction Continue

Write-Information "Instalando o actualizando modulo d365fo.tools" -InformationAction Continue
$installD365Script = Join-Path $ScriptDirectory "InstallOrUpdateD365foTools.ps1"
if (Test-Path $installD365Script) {
    & $installD365Script
} else {
    Write-Warning "No se encontró InstallOrUpdateD365foTools.ps1 en $installD365Script"
    Write-Information "Intentando instalar d365fo.tools directamente..." -InformationAction Continue
    if (-not (Get-Module -ListAvailable -Name d365fo.tools)) {
        Install-Module -Name d365fo.tools -Force -AllowClobber -Scope CurrentUser
    }
}

Write-Information "Importando modulo d365fo.tools" -InformationAction Continue
Import-Module -Name d365fo.tools 

# TODO Descartar este bloque para descargar. Luego implementaremos AzCopy
# Verificar si $urlDescarga o $rutaBacpac están vacíos
#if ([string]::IsNullOrEmpty($urlDescarga) -eq $false) {
    # Descargar el archivo desde la URL proporcionada
    #Write-Host -ForegroundColor Yellow "Descargando bacpac"
    #Invoke-WebRequest -Uri $urlDescarga -OutFile $rutaBacpac
    #ImprimirTiempoTranscurrido("Descargado el bacpac")
#}

# Quitar la marca "unblock" del archivo descargado
Unblock-File -Path $rutaBacpac

# Descarga e instalación de SqlPackage
if ($includeInstallSqlPackage) {
    Write-Information "Instalando SqlPackage" -InformationAction Continue
    #$SqlPackagePath = 'C:\Temp\d365fo.tools\SqlPackage'

    # # Version number: 162.1.167
    # # Build number: 162.1.167
    # # Release date: October 19, 2023
    # Invoke-D365InstallSqlPackage -Path $SqlPackagePath -SkipExtractFromPage -Url "https://go.microsoft.com/fwlink/?linkid=2249738"
    Invoke-D365InstallSqlPackage

    # Version number: 162.1.172
    # Build number: 162.1.172.1
    # Release date: January 9, 2024
    # dotnet tool install microsoft.sqlpackage --tool-path $SqlPackagePath --add-source https://api.nuget.org/v3/index.json
    
    ImprimirTiempoTranscurrido("SqlPackage instalado")
}

# Limpio tablas para agilizar el import
if (-not $skipCleanTables){
    $cleanScript = Join-Path $ScriptDirectory "SQL-CleanBacpac.ps1"
    if (Test-Path $cleanScript) {
        & $cleanScript -rutaBacpac $rutaBacpac -tables $tablesToClean -excludeTables $tablesToExclude
    } else {
        Write-Warning "No se encontró SQL-CleanBacpac.ps1 en $cleanScript. Saltando limpieza de tablas."
    }
}

$ImportedDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($rutaBacpac)

try {
    if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
        throw [System.IO.FileNotFoundException] $rutaBacpac
    }

    #uso una variable para guardar el mensaje a imprimir para poder reusarla en el catch
    $pasoActual = "Iniciando la importación de la base $ImportedDatabaseName con el archivo '$rutaBacpac'"
    # Ejecuto la importación
    Write-Information $pasoActual -InformationAction Continue
    Import-D365Bacpac -ImportModeTier1 -BacpacFile $rutaBacpac -NewDatabaseName $ImportedDatabaseName -MaxParallelism $MaxParallelism
    ImprimirTiempoTranscurrido("Bacpac importado")

    if ($includeSwitch) {
        $pasoActual = "Switcheando bases, deteniendo los servicios"
        Write-Information $pasoActual -InformationAction Continue
        Stop-D365Environment

        [int]$AxDB_Original = (Get-D365Database -Name AXDB_ORIGINAL | Measure-Object).Count
        if ($AxDB_Original -gt 0) {
            $pasoActual = "Switcheando bases, removiendo AxDB_original"
            Write-Information $pasoActual -InformationAction Continue
            Remove-D365Database -DatabaseName AxDB_original
        }
        ImprimirTiempoTranscurrido("AxDB switcheadas")

        Switch-D365ActiveDatabase -SourceDatabaseName $ImportedDatabaseName
        if (!$skipBuildModels) {
            $pasoActual = "Compilando los módulos DevAx* FamiliaBercomat"
            Write-Information $pasoActual -InformationAction Continue
            foreach ($model in $modelsToBuild) {
                Invoke-D365ProcessModule -Module $model -ExecuteCompile
            }   
            ImprimirTiempoTranscurrido("Compilación terminada")
        }

        $pasoActual = "Iniciando servicios"
        Write-Information $pasoActual -InformationAction Continue
        Start-D365EnvironmentV2 -Aos -Batch
        
        $pasoActual = "Sincronizando database"
        Write-Information $pasoActual -InformationAction Continue
        Invoke-D365DbSync
        ImprimirTiempoTranscurrido("DB sincronizada")
    }

    # TODO Falta implementar
    # if ($reinstallCsu) {
    #     [System.Environment]::MachineName
    #     ..\CommerceStoreScaleUnitSetupInstaller\InstallScaleUnit.ps1 ..\CommerceStoreScaleUnitSetupInstaller\ConfigFiles\
    #     ImprimirTiempoTranscurrido("CSU con extensiones reinstalado")
    # }
}
catch {
    Write-Error "Error desde el paso:"
    Write-Error "`t$pasoActual"
    Write-Error "`t$_.Exception.Message"
}

# Guarda la marca de tiempo de finalización
$fin = Get-Date
# Imprime las marcas de tiempo y el tiempo transcurrido
Write-Information  "Inicio: $inicio" -InformationAction Continue
Write-Information  "Final: $fin" -InformationAction Continue
$tiempoTranscurrido = $fin - $inicio
Write-Information  "Tiempo total transcurrido: $tiempoTranscurrido" -InformationAction Continue
