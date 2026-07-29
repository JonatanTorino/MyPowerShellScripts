<#
.SYNOPSIS
    Importa un archivo .bacpac como AxDB en un entorno D365FO Tier 1 y, opcionalmente,
    lo pone en producción haciendo el switch de base, la compilación y el DB sync.

.DESCRIPTION
    Orquesta la migración completa de una base AxDB en un entorno de nivel 1. El
    proceso se divide en fases visibles e independientes, cada una envuelta en un grupo
    colapsable del log de Azure DevOps, y al final imprime una tabla
    Fase | Duración | Estado con lo que se ejecutó y lo que se salteó.

    Fases, en orden: Verificar repo, Instalar d365fo.tools, Instalar SqlPackage,
    Limpiar bacpac, Importar bacpac, Detener servicios, Switch de base,
    Compilar modelos, Iniciar servicios, Sincronizar DB.

    CAMBIOS (2026-07-29):
    - EL SCRIPT AHORA FALLA DE VERDAD. Antes el catch imprimía el error en rojo y la
      ejecución continuaba hasta terminar con código 0, de modo que el pipeline daba
      verde aunque la base no se hubiera importado. Ahora el error se registra con
      "##vso[task.logissue type=error]" y el script termina con "exit 1".
    - Se corrigió la interpolación del mensaje de error. Estaba escrito como
      "$_.Exception.Message" dentro de comillas dobles: PowerShell interpola solo $_ y
      concatena el texto literal ".Exception.Message", así que el error real nunca se
      imprimía. Ahora usa $($_.Exception.Message).
    - Se agregó -ShowOriginalProgress a Import-D365Bacpac. Es la operación más larga de
      todo el pipeline (horas) y sin ese modificador la consola queda muda mientras
      corre. SQL-ExportBacpac.ps1 ya lo usaba en New-D365Bacpac.
    - Se agregaron -skipCleanTables, -tablesToClean, -tablesToExclude y -modelsToBuild
      para que el pipeline configure el comportamiento desde su JSON. Los tres últimos
      son [string] separados por comas, NO [string[]]: el pipeline pasa CSV para
      esquivar los problemas de comillas de YAML, y el split se hace adentro del
      script. Cadena vacía significa "no especificado" y cae al comportamiento previo.
    - Se eliminó código muerto: el parámetro -urlDescargarBacpac junto con su bloque de
      descarga (evaluaba $urlDescarga, una variable que nunca se declaraba, por lo que
      era inalcanzable), el parámetro -reinstallCsu con su bloque enteramente comentado
      y marcado "TODO Falta implementar", y un Import-Module de d365fo.tools duplicado.
    - La verificación de existencia del .bacpac se movió al principio. Antes se hacía
      recién después de instalar módulos y limpiar el archivo, es decir después de
      gastar tiempo en trabajo inútil.
    - CheckGitRepoUpdated.ps1 se invoca por $PSScriptRoot y no con la ruta relativa
      ".\", que solo resolvía si el directorio actual coincidía con el del script (en
      el agente no coincide). Además ese script hace Set-Location, así que acá se
      guarda y se restaura el directorio actual alrededor de la llamada.
    - SQL-CleanBacpac.ps1 pasó a invocarse con el operador & en vez de dot-sourcing.
      Dot-sourceado compartía el alcance y reiniciaba el estado de fases del helper de
      logging, además de anidar un "##[group]" dentro de otro, que Azure DevOps no
      soporta. Su código de salida se evalúa por $LASTEXITCODE.

    SEMÁNTICA QUE SE MANTIENE A PROPÓSITO:
    La compilación de modelos está anidada dentro de -includeSwitch. Es decir: sin
    -includeSwitch NO se compila, aunque no se haya pasado -skipBuildModels. Puede
    parecer un error, pero es el comportamiento histórico y hay corridas que dependen
    de él, así que se deja tal cual. Lo mismo vale para Detener servicios, Switch de
    base, Iniciar servicios y Sincronizar DB: todas cuelgan de -includeSwitch.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), porque el módulo d365fo.tools
    requiere 5.1. Por eso los steps del pipeline que llaman a este script van con
    "pwsh: false". Los agentes self-hosted de estos pipelines son siempre Windows;
    nunca se usa Linux.

.PARAMETER rutaBacpac
    Ruta completa al archivo .bacpac a importar. El nombre del archivo, sin extensión,
    se usa como nombre de la base de datos intermedia que se crea en el import.

.PARAMETER includeSwitch
    Ejecuta la puesta en producción de la base recién importada: detiene los servicios,
    elimina AxDB_original si existe, hace el switch de la base activa, compila los
    modelos, levanta los servicios y corre el DB sync. Sin este modificador el script
    solo deja la base importada al costado, sin tocar la que está en uso.

.PARAMETER includeInstallSqlPackage
    Instala o actualiza SqlPackage antes de importar (Invoke-D365InstallSqlPackage).
    Normalmente no hace falta: los agentes ya lo tienen instalado.

.PARAMETER skipBuildModels
    Omite la fase de compilación de modelos. Solo tiene efecto cuando además se pasó
    -includeSwitch, porque la compilación está anidada dentro de esa rama (ver
    DESCRIPTION).

.PARAMETER skipCheckGitRepoUpdated
    Omite la verificación de que el repositorio de scripts esté actualizado respecto
    del remoto. El pipeline la saltea siempre, porque clona el repositorio en cada
    corrida y la verificación no aporta nada en ese contexto.

.PARAMETER skipCleanTables
    Omite la fase de limpieza del .bacpac. Antes esa limpieza era incondicional y no
    había forma de evitarla cuando el bacpac ya venía limpio o se quería importar
    completo.

.PARAMETER tablesToClean
    Lista separada por comas de tablas a vaciar en el .bacpac; se reenvía tal cual a
    SQL-CleanBacpac.ps1. Admite comodines. Si se omite o llega vacía, ese script usa su
    lista por defecto.

.PARAMETER tablesToExclude
    Lista separada por comas de tablas que no deben limpiarse aunque coincidan con
    -tablesToClean; se reenvía tal cual a SQL-CleanBacpac.ps1. Si se omite o llega
    vacía, ese script usa su lista de exclusión por defecto.

.PARAMETER modelsToBuild
    Lista separada por comas de modelos a compilar, uno por invocación de
    Invoke-D365ProcessModule. Admite comodines. Si se omite o llega vacía se compilan
    los dos modelos históricos: 'DevAx*' y 'FamiliaBercomat'.

.PARAMETER MaxParallelism
    Grado de paralelismo que recibe Import-D365Bacpac. Por defecto 8.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac'

    Importa el bacpac dejando la base intermedia al costado, sin tocar la AxDB activa.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac' -includeSwitch

    Importa y pone la base en producción: switch, compilación de 'DevAx*' y
    'FamiliaBercomat', arranque de servicios y DB sync.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac "$(BacpacFullPath)" `
                           -includeSwitch `
                           -skipCheckGitRepoUpdated `
                           -tablesToClean 'DOCUHISTORY,BATCHJOBHISTORY,*Staging' `
                           -tablesToExclude 'dbo.AXXTAXFILEPARAMETERS' `
                           -modelsToBuild 'DevAx*,FamiliaBercomat'

    Forma en la que lo invoca el pipeline Migrate-DB: listas en CSV, provenientes del
    JSON de configuración.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac,

    [switch]$includeSwitch,

    [switch]$includeInstallSqlPackage,

    [switch]$skipBuildModels,

    [switch]$skipCheckGitRepoUpdated,

    [switch]$skipCleanTables,

    # Los tres parámetros de lista son CSV en un [string], no [string[]]: ver DESCRIPTION.
    [string]$tablesToClean,

    [string]$tablesToExclude,

    [string]$modelsToBuild,

    [int]$MaxParallelism = 8
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\PipelineLogging.ps1"

# Modelos que se compilaban hardcodeados antes de existir -modelsToBuild. Se conservan
# como valor por defecto para no cambiar el comportamiento de las corridas existentes.
[string[]]$modelosPorDefecto = @('DevAx*', 'FamiliaBercomat')

$inicio = Get-Date
$huboError = $false
$pasoActual = 'Validación inicial'

Write-Host "Inicio: $inicio"
Write-Host "Bacpac: $rutaBacpac"

try {
    # Validación temprana: fallar acá evita instalar módulos y limpiar un archivo que
    # no existe. Antes esta comprobación estaba después de esos pasos.
    if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró el archivo .bacpac indicado: $rutaBacpac")
    }

    $ImportedDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($rutaBacpac)
    Write-Host "Base de datos a crear: $ImportedDatabaseName"

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar repo'
    Start-Phase -Name $pasoActual
    if ($skipCheckGitRepoUpdated) {
        Write-Host 'Se saltea: se recibió -skipCheckGitRepoUpdated.'
        Complete-Phase -Status Skipped
    }
    else {
        # CheckGitRepoUpdated.ps1 hace Set-Location, que muta el directorio actual del
        # proceso; se guarda y se restaura para que las fases siguientes no dependan de
        # dónde quedó parado.
        $directorioPrevio = Get-Location
        try {
            & "$PSScriptRoot\CheckGitRepoUpdated.ps1" -rutaRepositorio $PSScriptRoot
        }
        finally {
            Set-Location -Path $directorioPrevio
        }
        Complete-Phase
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Instalar d365fo.tools'
    Start-Phase -Name $pasoActual
    . "$PSScriptRoot\InstallOrUpdateD365foTools.ps1"
    Write-Host 'Importando el módulo d365fo.tools'
    Import-Module -Name d365fo.tools
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Instalar SqlPackage'
    Start-Phase -Name $pasoActual
    if ($includeInstallSqlPackage) {
        Invoke-D365InstallSqlPackage
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeInstallSqlPackage.'
        Complete-Phase -Status Skipped
    }

    # Quita la marca "unblock" que Windows le pone a los archivos traídos de otra
    # máquina; sin esto SqlPackage puede rechazar el .bacpac.
    Unblock-File -Path $rutaBacpac

    # -------------------------------------------------------------------------
    $pasoActual = 'Limpiar bacpac'
    Start-Phase -Name $pasoActual
    if ($skipCleanTables) {
        Write-Host 'Se saltea: se recibió -skipCleanTables.'
        Complete-Phase -Status Skipped
    }
    else {
        # $LASTEXITCODE es global y conserva el código del último comando nativo que se
        # haya ejecutado (por ejemplo los git de la fase "Verificar repo"). Se resetea
        # para que la comprobación de abajo mida únicamente a este hijo.
        $global:LASTEXITCODE = 0

        # Se invoca con & (alcance propio) y no con dot-sourcing: ver DESCRIPTION.
        # -skipPhaseLogging evita que el hijo abra un "##[group]" dentro de este.
        & "$PSScriptRoot\SQL-CleanBacpac.ps1" `
            -rutaBacpac $rutaBacpac `
            -tablesToClean $tablesToClean `
            -tablesToExclude $tablesToExclude `
            -skipPhaseLogging

        # El hijo termina con exit 1 ante un fallo; eso no lanza excepción en el
        # llamador, así que hay que revisar el código de salida a mano.
        if ($LASTEXITCODE -ne 0) {
            throw "SQL-CleanBacpac.ps1 terminó con código $LASTEXITCODE."
        }
        Complete-Phase
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Importar bacpac'
    Start-Phase -Name $pasoActual
    Write-Host "Importando la base $ImportedDatabaseName desde '$rutaBacpac' (MaxParallelism $MaxParallelism)"
    # -ShowOriginalProgress es lo que hace que SqlPackage escriba su progreso en el log
    # del run. Sin eso este paso, que dura horas, no imprime absolutamente nada.
    Import-D365Bacpac -ImportModeTier1 `
        -BacpacFile $rutaBacpac `
        -NewDatabaseName $ImportedDatabaseName `
        -MaxParallelism $MaxParallelism `
        -ShowOriginalProgress
    Complete-Phase

    # -------------------------------------------------------------------------
    # Todo lo que sigue depende de -includeSwitch (ver DESCRIPTION). Sin ese
    # modificador las cinco fases restantes se registran como salteadas.
    $pasoActual = 'Detener servicios'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Stop-D365Environment

        [int]$AxDB_Original = (Get-D365Database -Name AXDB_ORIGINAL | Measure-Object).Count
        if ($AxDB_Original -gt 0) {
            Write-Host 'Removiendo la base AxDB_original de una migración anterior'
            Remove-D365Database -DatabaseName AxDB_original
        }
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Switch de base'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Write-Host "Activando la base $ImportedDatabaseName como AxDB"
        Switch-D365ActiveDatabase -SourceDatabaseName $ImportedDatabaseName
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Compilar modelos'
    Start-Phase -Name $pasoActual
    if ($includeSwitch -and -not $skipBuildModels) {
        # Cadena vacía = no especificado = se compilan los modelos históricos.
        $modelosACompilar = ConvertTo-ListaDesdeCsv -Csv $modelsToBuild
        if ($modelosACompilar.Count -eq 0) {
            $modelosACompilar = $modelosPorDefecto
            Write-Host 'No se recibió -modelsToBuild; se usa la lista de modelos por defecto.'
        }

        Write-Host "Modelos a compilar: $($modelosACompilar -join ', ')"
        foreach ($modelo in $modelosACompilar) {
            Write-Host "Compilando '$modelo'"
            Invoke-D365ProcessModule -Module $modelo -ExecuteCompile
        }
        Complete-Phase
    }
    else {
        if (-not $includeSwitch) {
            Write-Host 'Se saltea: no se recibió -includeSwitch (la compilación cuelga de esa rama).'
        }
        else {
            Write-Host 'Se saltea: se recibió -skipBuildModels.'
        }
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Iniciar servicios'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Start-D365EnvironmentV2 -Aos -Batch
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Sincronizar DB'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Invoke-D365DbSync
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }
}
catch {
    # Cierra como fallida la fase que estuviera abierta, para que el "##[endgroup]"
    # salga igual y la fila aparezca en el resumen.
    Complete-Phase -Status Failed
    Write-PipelineError -Message "Falló la fase '$pasoActual': $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $huboError = $true
}
finally {
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
