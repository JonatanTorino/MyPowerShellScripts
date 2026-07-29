<#
.SYNOPSIS
    Exporta la base AxDB de un entorno D365FO Tier 1 a un archivo .bacpac y publica su
    ruta exacta como variable de salida de Azure DevOps.

.DESCRIPTION
    Genera el .bacpac con New-D365Bacpac -ExportModeTier1 en el directorio destino, con
    un nombre que incluye la base, el nombre de la máquina y la marca de tiempo de la
    corrida. El trabajo se divide en fases visibles en el log del run y termina con una
    tabla Fase | Duración | Estado.

    CAMBIOS (2026-07-29):
    - EL SCRIPT AHORA FALLA DE VERDAD. Antes el catch imprimía el error en rojo y el
      script terminaba con código 0, de modo que el pipeline daba verde aunque no se
      hubiera generado el .bacpac. Ahora el error se registra con
      "##vso[task.logissue type=error]" y el script termina con "exit 1".
    - Se publica el nombre exacto del archivo generado como variable de salida:
      "##vso[task.setvariable variable=ExportedBacpacFile;isOutput=true]". Hasta ahora
      el pipeline resolvía el .bacpac tomando el más reciente de la carpeta destino, lo
      que ante un export fallido puede levantar el archivo de una corrida ANTERIOR y
      migrar una base vieja a todos los entornos mostrando verde. Con la ruta explícita
      esa adivinanza deja de ser necesaria.
      NOTA: "isOutput=true" exige que el step de PowerShell tenga un "name:" definido en
      el YAML; el step que invoca este script ya lo tiene.
    - Antes de dar el export por exitoso se verifica que el archivo exista Y que su
      LastWriteTime sea posterior a la marca de inicio de esta corrida. Un archivo
      preexistente con el mismo nombre ya no puede hacerse pasar por recién generado.
    - El finally que borra el directorio temporal ya no puede enmascarar un fallo
      previo: va dentro de su propio try/catch y, si falla, solo emite una advertencia
      sin alterar el resultado ni el código de salida del script.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), porque el módulo d365fo.tools
    requiere 5.1. Por eso el step del pipeline que llama a este script va con
    "pwsh: false". Los agentes self-hosted de estos pipelines son siempre Windows;
    nunca se usa Linux.

.PARAMETER BackupDirectory
    Directorio temporal que usa New-D365Bacpac para el backup intermedio. Se borra al
    finalizar, haya salido bien o mal.

.PARAMETER NewDatabaseName
    Nombre de la copia de trabajo que crea el export y que se usa como prefijo del
    archivo .bacpac resultante.

.PARAMETER TargetPath
    Directorio donde queda el .bacpac generado. Es el que después lee el pipeline para
    publicar el artefacto.

.PARAMETER ExtraDescription
    Texto opcional que se agrega al nombre del archivo, después de la marca de tiempo.
    Se le quitan los espacios. Sirve para distinguir exports manuales.

.EXAMPLE
    .\SQL-ExportBacpac.ps1

    Export con los valores por defecto: temporal en J:\MSSQL_BACKUPTEMP y .bacpac en
    J:\MSSQL_BACKUP.

.EXAMPLE
    .\SQL-ExportBacpac.ps1 -BackupDirectory 'J:\MSSQL_BACKUPTEMP' `
                           -TargetPath 'J:\MSSQL_BACKUP'

    Forma en la que lo invoca el pipeline Migrate-DB, con los directorios que vienen del
    JSON de configuración.

.EXAMPLE
    .\SQL-ExportBacpac.ps1 -ExtraDescription 'previo a upgrade'

    Genera AxDB_Backup-<maquina>-<fecha>_previoaupgrade.bacpac.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = 'J:\MSSQL_BACKUPTEMP',

    [Parameter(Mandatory = $false)]
    [string]$NewDatabaseName = 'AxDB_Backup',

    [Parameter(Mandatory = $false)]
    [string]$TargetPath = 'J:\MSSQL_BACKUP',

    [Parameter(Mandatory = $false)]
    [string]$ExtraDescription = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\PipelineLogging.ps1"

# Marca de inicio: además de medir, es la referencia contra la que se valida que el
# .bacpac sea realmente de esta corrida y no de una anterior.
$inicio = Get-Date
$huboError = $false
$pasoActual = 'Preparar directorios'
$BacpacFile = $null

Write-Host "Inicio: $inicio"

try {
    # -------------------------------------------------------------------------
    $pasoActual = 'Preparar directorios'
    Start-Phase -Name $pasoActual
    foreach ($ruta in @($TargetPath, $BackupDirectory)) {
        if (-not (Test-Path $ruta)) {
            Write-Host "Creando directorio: $ruta"
            New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        }
    }

    # Nombre del archivo: base + máquina + marca de tiempo, para que dos corridas nunca
    # se pisen y el origen de cada .bacpac sea evidente desde el nombre.
    $nombreArchivo = "$NewDatabaseName-$env:computername-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    if (-not [string]::IsNullOrWhiteSpace($ExtraDescription)) {
        $nombreArchivo += "_$($ExtraDescription.Replace(' ', ''))"
    }
    $nombreArchivo += '.bacpac'
    $BacpacFile = Join-Path $TargetPath $nombreArchivo

    Write-Host "Directorio de backup temporal : $BackupDirectory"
    Write-Host "Directorio destino            : $TargetPath"
    Write-Host "Base de datos                 : $NewDatabaseName"
    Write-Host "Archivo BACPAC                : $BacpacFile"
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Exportar bacpac'
    Start-Phase -Name $pasoActual
    New-D365Bacpac -ExportModeTier1 `
        -BackupDirectory $BackupDirectory `
        -NewDatabaseName $NewDatabaseName `
        -BacpacFile $BacpacFile `
        -ShowOriginalProgress
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar archivo'
    Start-Phase -Name $pasoActual
    if (-not (Test-Path -Path $BacpacFile -PathType Leaf)) {
        throw "No se generó el archivo $BacpacFile."
    }

    $infoArchivo = Get-Item $BacpacFile

    # No alcanza con que el archivo exista: tiene que haberse escrito DESPUÉS del inicio
    # de esta corrida. Si no, es el sobrante de una ejecución anterior y darlo por bueno
    # implicaría migrar una base vieja a todos los entornos mostrando verde.
    if ($infoArchivo.LastWriteTime -le $inicio) {
        throw "El archivo $BacpacFile es anterior al inicio de esta corrida (LastWriteTime $($infoArchivo.LastWriteTime), inicio $inicio); no corresponde a esta ejecución."
    }

    Write-Host "Archivo generado correctamente: $BacpacFile" -ForegroundColor Green
    Write-Host ('Tamaño del archivo: {0:N2} GB' -f ($infoArchivo.Length / 1GB))
    Write-Host "Última escritura  : $($infoArchivo.LastWriteTime)"

    # Ruta exacta del archivo de ESTA corrida, para que el pipeline no tenga que
    # adivinar cuál es el .bacpac más reciente de la carpeta (ver DESCRIPTION).
    Write-Host "##vso[task.setvariable variable=ExportedBacpacFile;isOutput=true]$BacpacFile"
    Complete-Phase
}
catch {
    Complete-Phase -Status Failed
    Write-PipelineError -Message "Falló la fase '$pasoActual' del export: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $huboError = $true
}
finally {
    # La limpieza del temporal corre siempre, pero envuelta en su propio try/catch: un
    # fallo borrando archivos no debe pisar ni ocultar el error real de arriba, ni
    # cambiar el código de salida del script.
    if (Test-Path $BackupDirectory) {
        try {
            Write-Host "Limpiando el directorio temporal $BackupDirectory"
            Remove-Item -Path $BackupDirectory -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "No se pudo limpiar el directorio temporal '$BackupDirectory': $($_.Exception.Message)"
        }
    }

    Write-PhaseSummary

    $fin = Get-Date
    Write-Host "Inicio: $inicio"
    Write-Host "Final : $fin"
    Write-Host "Tiempo total transcurrido: $($fin - $inicio)" -ForegroundColor Magenta
}

# El exit va después del finally para que el resumen salga una sola vez y siempre, y
# para que el código de salida sea el que decide si el step del pipeline queda en rojo.
if ($huboError) {
    exit 1
}
