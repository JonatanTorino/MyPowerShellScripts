[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac
    ,
    # [Parameter(Mandatory=$true)]
    [string]$urlDescargarBacpac
    ,
    [switch]$includeSwitch = $false
    ,
    [switch]$includeInstallSqlPackage = $false
    ,
    [switch]$skipBuildModels = $false
    ,
    [switch]$reinstallCsu = $false
    ,
    [switch]$skipCheckGitRepoUpdated = $false
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
    Write-Host -ForegroundColor Green "$mensaje, Tiempo transcurrido : $tiempoTranscurrido"
}

if (!$skipCheckGitRepoUpdated) {
    .\CheckGitRepoUpdated.ps1 . # el . representa el directorio actual
}

# Guarda la marca de tiempo de inicio
$inicio = Get-Date
Write-Host "Inicio: $inicio"

# Write-Host "Instalando o actualizando modulo d365fo.tools"
. "$PSScriptRoot\InstallOrUpdateD365foTools.ps1"

Write-Host "Importando modulo d365fo.tools"
Import-Module -Name d365fo.tools
Import-Module -Name d365fo.tools

# TODO Descartar este bloque para descargar. Luego implementaremos AzCopy
# Verificar si $urlDescarga o $rutaBacpac están vacíos
if ([string]::IsNullOrEmpty($urlDescarga) -eq $false) {
    # Descargar el archivo desde la URL proporcionada
    Write-Host -ForegroundColor Yellow "Descargando bacpac"
    Invoke-WebRequest -Uri $urlDescarga -OutFile $rutaBacpac
    ImprimirTiempoTranscurrido("Descargado el bacpac")
}

# Quitar la marca "unblock" del archivo descargado
Unblock-File -Path $rutaBacpac

# Descarga e instalación de SqlPackage
if ($includeInstallSqlPackage) {
    Write-Host -ForegroundColor Yellow "Instalando SqlPackage"
    $SqlPackagePath = 'C:\Temp\d365fo.tools\SqlPackage'

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
. "$PSScriptRoot\SQL-CleanBacpac.ps1" -rutaBacpac $rutaBacpac
$ImportedDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($rutaBacpac)

try {
    if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
        throw [System.IO.FileNotFoundException] $rutaBacpac
    }

    #uso una variable para guardar el mensaje a imprimir para poder reusarla en el catch
    $pasoActual = "Iniciando la importación de la base $ImportedDatabaseName con el archivo '$rutaBacpac'"
    # Ejecuto la importación
    Write-Host -ForegroundColor Yellow $pasoActual
    Import-D365Bacpac -ImportModeTier1 -BacpacFile $rutaBacpac -NewDatabaseName $ImportedDatabaseName -MaxParallelism $MaxParallelism
    ImprimirTiempoTranscurrido("Bacpac importado")

    if ($includeSwitch) {
        $pasoActual = "Switcheando bases, deteniendo los servicios"
        Write-Host -ForegroundColor Yellow $pasoActual
        Stop-D365Environment

        [int]$AxDB_Original = (Get-D365Database -Name AXDB_ORIGINAL | Measure-Object).Count
        if ($AxDB_Original -gt 0) {
            $pasoActual = "Switcheando bases, removiendo AxDB_original"
            Write-Host -ForegroundColor Yellow $pasoActual
            Remove-D365Database -DatabaseName AxDB_original
        }
        ImprimirTiempoTranscurrido("AxDB switcheadas")

        Switch-D365ActiveDatabase -SourceDatabaseName $ImportedDatabaseName
        if (!$skipBuildModels) {
            $pasoActual = "Compilando los módulos DevAx* FamiliaBercomat"
            Write-Host -ForegroundColor Yellow $pasoActual
            Invoke-D365ProcessModule -Module "DevAx*" -ExecuteCompile
            Invoke-D365ProcessModule -Module "FamiliaBercomat" -ExecuteCompile
            ImprimirTiempoTranscurrido("Compilación terminada")
        }

        $pasoActual = "Iniciando servicios"
        Write-Host -ForegroundColor Yellow $pasoActual
        Start-D365EnvironmentV2 -Aos -Batch
        
        $pasoActual = "Sincronizando database"
        Write-Host -ForegroundColor Yellow $pasoActual
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
    Write-Host -ForegroundColor Red "Error desde el paso:"
    Write-Host -ForegroundColor Red "`t$pasoActual"
    Write-Host -ForegroundColor Red "`t$_.Exception.Message"
}

# Guarda la marca de tiempo de finalización
$fin = Get-Date
# Imprime las marcas de tiempo y el tiempo transcurrido
Write-Host "Inicio: $inicio"
Write-Host "Final: $fin"
$tiempoTranscurrido = $fin - $inicio
Write-Host -ForegroundColor Magenta "Tiempo total transcurrido: $tiempoTranscurrido"
