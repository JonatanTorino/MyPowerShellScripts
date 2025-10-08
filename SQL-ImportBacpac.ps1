[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac
    #,
    # [Parameter(Mandatory=$true)]
    #[string]$urlDescargarBacpac
    ,
    [switch]$includeSwitch = $false
    ,
    [switch]$includeInstallSqlPackage = $false
    ,
    [switch]$skipBuildModels = $false
    #,
    #[switch]$reinstallCsu = $false
    ,
    [string[]]$tablesToClean
    ,
    [string[]]$tablesToExclude
    ,
    [string[]]$modulesToBuild
    ,
    [switch]$skipCheckGitRepoUpdated = $false
    ,
    [switch]$skipCleanTables = $false
    ,
    [int] $MaxParallelism = 8
)

function ImprimirTiempoTranscurrido {
    param (
        [string]$mensaje
    )
    
    # Calcula la diferencia de tiempo
    $horaActual = Get-Date
    $tiempoTranscurrido = $horaActual - $inicio
    # Imprime las marcas de tiempo y el tiempo transcurrido
    Write-Information  -ForegroundColor Green "$mensaje, Tiempo transcurrido : $tiempoTranscurrido" -InformationAction Continue
}

if (!$skipCheckGitRepoUpdated) {
    .\CheckGitRepoUpdated.ps1 . # el . representa el directorio actual
}

# Guarda la marca de tiempo de inicio
$inicio = Get-Date
Write-Information "Inicio: $inicio" -InformationAction Continue

Write-Information "Instalando o actualizando modulo d365fo.tools" -InformationAction Continue
.\InstallOrUpdateD365foTools.ps1

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
if (!$skipCleanTables){
    .\SQL-CleanBacpac.ps1 -rutaBacpac $rutaBacpac -tables $tablesToClean -excludeTables $tablesToExclude
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
            foreach ($module in $modulesToBuild) {
                Invoke-D365ProcessModule -Module $module -ExecuteCompile
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
Write-Information  -ForegroundColor Magenta "Tiempo total transcurrido: $tiempoTranscurrido" -InformationAction Continue
