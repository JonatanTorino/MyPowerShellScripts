<#
.SYNOPSIS
    Vacía las tablas de log y de staging dentro de un archivo .bacpac de AxDB para
    acelerar su posterior importación.

.DESCRIPTION
    Trabaja sobre el .bacpac en disco (Get-D365BacpacTable / Clear-D365BacpacTableData
    con -ClearFromSource), sin tocar ninguna base de datos: elimina de la copia los
    datos de tablas históricas y de integración que no aportan nada en el entorno
    destino y que son las que más pesan.

    Se usa de dos maneras: invocado por SQL-ImportBacpac.ps1 como una fase más de la
    migración, o a mano contra un .bacpac suelto. Por eso las listas de tablas tienen
    valores por defecto: sin parámetros hace una limpieza razonable de una AxDB.

    LISTAS EN FORMATO CSV:
    -tablesToClean y -tablesToExclude son [string] separados por comas, NO [string[]].
    El pipeline pasa CSV para esquivar los problemas de comillas de YAML y el split se
    hace adentro del script. Cadena vacía significa "no especificado" y cae a la lista
    por defecto.

    MANEJO DE ERRORES:
    Corre con $ErrorActionPreference='Stop'. Ante cualquier fallo registra el error con
    Write-PipelineError y termina con "exit 1", para que el step del pipeline quede en
    rojo en vez de dar verde sobre un bacpac sin limpiar.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), porque el módulo d365fo.tools
    requiere 5.1. Los agentes self-hosted de estos pipelines son siempre Windows;
    nunca se usa Linux.

.PARAMETER rutaBacpac
    Ruta completa al archivo .bacpac a limpiar. El archivo se modifica in situ.

.PARAMETER tablesToClean
    Lista separada por comas de las tablas cuyos datos se vacían. Admite comodines
    (por ejemplo 'AxxTaxFile*' o '*Staging'), que resuelve Get-D365BacpacTable.
    Si se omite o llega vacía se usa la lista por defecto: los logs de plataforma y
    auditoría (DOCUHISTORY, EVENTCUD, SYSEXCEPTIONTABLE, SYSUSERLOG, SYSDATABASELOG...),
    el juego completo de tablas BATCH*, el log de ejecución de procesos
    (PROCESSEXECUTION*) y el staging de importaciones (DMFSTAGING*, '*Staging').

    Esta lista es la misma que el pipeline Migrate-DB-MultiEnv define en su JSON de
    configuración, de modo que una corrida manual sin parámetros limpie exactamente lo
    mismo que una corrida del pipeline.

.PARAMETER tablesToExclude
    Lista separada por comas de tablas que NO deben limpiarse aunque coincidan con
    -tablesToClean. Se compara contra el nombre calificado con esquema, tal como lo
    devuelve Get-D365BacpacTable (por ejemplo 'dbo.AXXTAXFILEPARAMETERS').
    Si se omite o llega vacía se usa la lista de exclusión por defecto.

.PARAMETER skipPhaseLogging
    Omite la apertura de fase y el resumen final. Lo usa SQL-ImportBacpac.ps1, que ya
    contabiliza esta operación como una de sus fases. En uso manual no se pasa.

.EXAMPLE
    .\SQL-CleanBacpac.ps1 -rutaBacpac 'J:\MSSQL_BACKUP\AxDB_Backup.bacpac'

    Limpia el bacpac con las listas por defecto (uso manual).

.EXAMPLE
    .\SQL-CleanBacpac.ps1 -rutaBacpac 'J:\MSSQL_BACKUP\AxDB_Backup.bacpac' `
                          -tablesToClean 'DOCUHISTORY,BATCHJOBHISTORY,*Staging' `
                          -tablesToExclude 'dbo.AXXTAXFILEPARAMETERS'

    Forma en la que lo invoca el pipeline: listas en CSV, provenientes del JSON de
    configuración.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac,

    # CSV, no [string[]]: ver DESCRIPTION.
    [Parameter(Mandatory = $false)]
    [string]$tablesToClean,

    [Parameter(Mandatory = $false)]
    [string]$tablesToExclude,

    [switch]$skipPhaseLogging
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\PipelineLogging.ps1"

# Listas por defecto: son las que tenía hardcodeadas el script y se conservan para que
# siga siendo usable a mano, sin parámetros.
# Logs de plataforma y de auditoría.
[string[]]$tablasPorDefecto = @('DOCUHISTORY', 'EVENTCUD', 'SYSEXCEPTIONTABLE', 'SYSENCRYPTIONLOG', 'SMMTransLog', 'SYSUSERLOG', 'SYSDATABASELOG', 'SYSDATABASELOGLINES')

# Juego completo de BATCH*. BATCHHISTORY suele ser la tabla más grande de una AxDB de
# desarrollo: en un entorno medido concentraba el 17% de las filas de toda la base.
$tablasPorDefecto += @('BATCH', 'BATCHCONSTRAINTS', 'BATCHCONSTRAINTSHISTORY', 'BATCHHISTORY', 'BATCHJOB', 'BATCHJOBALERTS', 'BATCHJOBHISTORY', 'BATCHJOBRECURRENCECOUNT')

# Log de ejecución de procesos (DMF y afines).
$tablasPorDefecto += @('PROCESSEXECUTIONSTATUSLOG', 'PROCESSEXECUTIONMESSAGELOG', 'PROCESSEXECUTIONSOURCELINK')

# Staging de importaciones. El comodín cubre las tablas de staging de las entidades de
# datos, que se regeneran solas en el destino.
$tablasPorDefecto += @('DMFSTAGINGLOGDETAILS', 'DMFSTAGINGVALIDATIONLOG', '*Staging')

[string[]]$exclusionesPorDefecto = @('dbo.OTRAS_TABLAS')

$huboError = $false

try {
    if (-not $skipPhaseLogging) {
        Start-Phase -Name "Limpiar bacpac $([System.IO.Path]::GetFileName($rutaBacpac))"
    }

    if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró el archivo .bacpac a limpiar: $rutaBacpac")
    }

    # Cadena vacía = no especificado = se usa el valor por defecto.
    $listaALimpiar = ConvertTo-ListaDesdeCsv -Csv $tablesToClean
    if ($listaALimpiar.Count -eq 0) {
        $listaALimpiar = $tablasPorDefecto
        Write-Host 'No se recibió -tablesToClean; se usa la lista de tablas por defecto.'
    }

    $listaAExcluir = ConvertTo-ListaDesdeCsv -Csv $tablesToExclude
    if ($listaAExcluir.Count -eq 0) {
        $listaAExcluir = $exclusionesPorDefecto
        Write-Host 'No se recibió -tablesToExclude; se usa la lista de exclusiones por defecto.'
    }

    Write-Host "Bacpac      : $rutaBacpac"
    Write-Host "Patrones    : $($listaALimpiar -join ', ')"
    Write-Host "Exclusiones : $($listaAExcluir -join ', ')"

    # @() fuerza arreglo: con una sola coincidencia el cmdlet devuelve un objeto suelto
    # y .Count no daría el resultado esperado.
    $tablasResueltas = @(Get-D365BacpacTable -Path $rutaBacpac -Table $listaALimpiar)
    $tablasResueltas = @($tablasResueltas | Where-Object { $_.Name -notin $listaAExcluir })

    if ($tablasResueltas.Count -eq 0) {
        Write-Host 'No se encontraron tablas para limpiar; posiblemente el bacpac ya está limpio.' -ForegroundColor Yellow
    }
    else {
        Write-Host "Tablas a limpiar ($($tablasResueltas.Count)):" -ForegroundColor Yellow
        $tablasResueltas | Format-Table -AutoSize | Out-String | Write-Host

        $tamanioOriginal = ($tablasResueltas | Measure-Object OriginalSize -Sum).Sum / 1GB
        Write-Host ('Tamaño original total a liberar: {0:N2} GB' -f $tamanioOriginal) -ForegroundColor Green

        $nombresTablas = @($tablasResueltas | Select-Object -ExpandProperty Name)

        Write-Host 'Ejecutando limpieza...' -ForegroundColor Yellow
        Clear-D365BacpacTableData -Path $rutaBacpac -Table $nombresTablas -ClearFromSource
        Write-Host 'Limpieza finalizada.' -ForegroundColor Green
    }

    if (-not $skipPhaseLogging) {
        Complete-Phase
    }
}
catch {
    # Se cierra la fase abierta como fallida antes de reportar, para que el grupo del
    # log quede cerrado y la fila aparezca en el resumen.
    if (-not $skipPhaseLogging) {
        Complete-Phase -Status Failed
    }

    # El detalle siempre se imprime. El comando de error de Azure DevOps lo emite solo
    # el script de más arriba, para no duplicar el mismo issue en el resumen del run.
    Write-Host "Falló la limpieza del bacpac '$rutaBacpac': $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red

    if (-not $skipPhaseLogging) {
        Write-PipelineError -Message "Falló la limpieza del bacpac '$rutaBacpac': $($_.Exception.Message)"
    }

    $huboError = $true
}
finally {
    if (-not $skipPhaseLogging) {
        Write-PhaseSummary
    }
}

# El exit va después del finally para que el resumen se imprima una sola vez y siempre.
# Invocado con el operador & desde SQL-ImportBacpac.ps1, este código queda en
# $LASTEXITCODE y es lo que el llamador evalúa para cortar la migración.
if ($huboError) {
    exit 1
}

# El exit 0 explícito no es decorativo: sin él, un final normal no toca $LASTEXITCODE y
# el llamador leería el código del último comando nativo que se hubiera ejecutado antes.
exit 0
