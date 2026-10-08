<#
.SYNOPSIS
    Importa un archivo .bacpac como AxDB en un entorno D365FO Tier 1 y, opcionalmente,
    lo pone en producción haciendo el switch de base, la compilación y el DB sync.

.DESCRIPTION
    Orquesta la migración completa de una base AxDB en un entorno de nivel 1. El
    proceso se divide en fases visibles e independientes, cada una envuelta en un grupo
    colapsable del log de Azure DevOps, y al final imprime una tabla
    Fase | Duración | Estado con lo que se ejecutó y lo que se salteó.

    Fases, en orden: Verificar repo, Instalar d365fo.tools, Verificar base destino,
    Instalar SqlPackage, Limpiar bacpac, Importar bacpac, Detener servicios,
    Switch de base, Compilar modelos, Iniciar servicios, Sincronizar DB.

    LA BASE DESTINO NO PUEDE EXISTIR DE ANTEMANO:
    SqlPackage solo importa sobre una base nueva y vacía. Si ya existe una base con el
    nombre del .bacpac (por ejemplo, el resto de una importación anterior que se cortó),
    el script falla en 'Verificar base destino', antes de tocar el .bacpac, y no la
    borra: decidir si se descarta es del operador.

    CÓMO SE DECIDE QUE LA IMPORTACIÓN TERMINÓ BIEN:
    la importación corre en un proceso aparte (SQL-ImportBacpacSqlPackage.ps1) cuya
    salida se lee línea por línea y se reenvía al log. Se da por buena solo si
    SqlPackage informó "Successfully imported database" y no informó ningún error. Que
    la base exista no alcanza: una importación cortada también deja la base creada.

    Sin -includeSwitch el script se detiene después de importar: la base queda al
    costado, en paralelo, y el entorno en uso no se toca. Con -includeSwitch se
    ejecutan además las cinco fases finales, que sí modifican el entorno.

    EL ORDEN DE LAS ÚLTIMAS FASES ES DELIBERADO:
    Detener servicios -> Switch de base -> Compilar modelos -> Iniciar servicios ->
    Sincronizar DB. NO reordenar. El switch va primero porque es lo que deja la base
    importada en su lugar; la compilación va después para garantizar que no quede
    ningún cambio de metadata sin reflejar en los binarios; y recién entonces el DB
    sync concilia la estructura de la base con la versión de los modelos instalados,
    que es lo que deja el entorno destino operativo. Compilar antes del switch dejaría
    binarios construidos contra la base vieja, y sincronizar antes de compilar
    aplicaría a la base una estructura que los binarios todavía no conocen.

    ESCENARIOS DE MIGRACIÓN QUE CUBRE ESTE ORDEN:
    - Modelos coincidentes entre origen y destino: la estructura no cambia y el DB
      sync no tiene nada que reconciliar.
    - Origen con MÁS modelos que el destino: la base importada trae tablas y campos de
      modelos que el destino no tiene instalados. Esos objetos quedan en la base pero
      sin código que los use; no rompen la operación.
    - Mismos modelos en versiones distintas: la compilación deja los binarios en la
      versión del destino y el DB sync ajusta la estructura de la base a esa versión.
    - Origen con MENOS modelos que el destino: la base importada llega sin los datos de
      esos modelos, cosa que se acepta al correr el pipeline, y el DB sync vuelve a
      crear las estructuras faltantes para que la aplicación siga operable.

    LAS FASES FINALES CUELGAN DE -includeSwitch:
    Detener servicios, Switch de base, Compilar modelos, Iniciar servicios y
    Sincronizar DB solo se ejecutan con -includeSwitch. En particular, sin ese
    modificador NO se compila, aunque no se haya pasado -skipBuildModels.

    QUÉ PASA SI SE PIDIÓ COMPILAR Y -modelsToBuild LLEGA VACÍO:
    La importación del bacpac es el objetivo primario, es cara (2-3 horas) pero NO es
    destructiva: la base aterriza en una base paralela. El switch SÍ es destructivo.
    De ahí el tratamiento asimétrico:
    1. Al principio de todo, antes de cualquier trabajo largo, se emite una ADVERTENCIA
       ("##vso[task.logissue type=warning]") avisando que la importación va a correr
       pero que el proceso se va a detener antes del switch. NO se aborta: el operador
       ve el problema en el minuto 1 en vez de descubrirlo después de tres horas, y
       puede cancelar la corrida si quiere.
    2. Al terminar la importación, si la condición sigue vigente, se registra un ERROR,
       se imprime el resumen de fases y se sale con "exit 1" ANTES de detener
       servicios, hacer el switch, compilar o sincronizar. El entorno destino queda
       operativamente intacto y la base importada queda en su lugar, lista para que
       alguien termine el trabajo a mano.

    LIMITACIÓN CONOCIDA DE LA FASE 'Compilar modelos':
    esa fase NO hace fallar el step si xppc.exe devuelve error, porque
    -ShowOriginalProgress hace que d365fo.tools saltee su propio chequeo del código de
    salida. Para verificar el resultado real hay que mirar los logs de xppc, cuyas
    rutas se imprimen al final de la fase.

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

.PARAMETER includeUpdateD365foTools
    Busca en PowerShell Gallery una versión más reciente de d365fo.tools y, si la hay,
    actualiza el módulo (InstallOrUpdateD365foTools.ps1). Sin este modificador se usa
    la versión instalada y no se consulta la galería. Si el módulo no está instalado,
    se instala igual, con o sin este modificador.

.PARAMETER skipBuildModels
    Omite la fase de compilación de modelos. Solo tiene efecto cuando además se pasó
    -includeSwitch, porque la compilación está anidada dentro de esa rama (ver
    DESCRIPTION).

.PARAMETER skipCheckGitRepoUpdated
    Omite la verificación de que el repositorio de scripts esté actualizado respecto
    del remoto. El pipeline la saltea siempre, porque clona el repositorio en cada
    corrida y la verificación no aporta nada en ese contexto.

.PARAMETER skipCleanTables
    Omite la fase de limpieza del .bacpac. Útil cuando el archivo ya viene limpio o
    cuando se quiere importar la base completa.

.PARAMETER tablesToClean
    Lista separada por comas de tablas a vaciar en el .bacpac; se reenvía tal cual a
    SQL-CleanBacpac.ps1. Admite comodines. Si se omite o llega vacía, ese script usa su
    lista por defecto.

.PARAMETER tablesToExclude
    Lista separada por comas de tablas que no deben limpiarse aunque coincidan con
    -tablesToClean; se reenvía tal cual a SQL-CleanBacpac.ps1. Si se omite o llega
    vacía, ese script usa su lista de exclusión por defecto.

.PARAMETER modelsToBuild
    Lista separada por comas de patrones de búsqueda de módulos a compilar. Admite
    comodines: cada entrada del CSV se usa tal cual como -Name de Get-D365Module, los
    resultados de todos los patrones se acumulan y se deduplican por nombre de módulo,
    y el conjunto entero se manda por pipe a Invoke-D365ModuleCompile. Sirve tanto
    'Axxon 365*' como 'Axxon 365*,DevAx*'.

    NO tiene valor por defecto y no se cae a ninguna lista histórica ni al comodín '*'.
    Si se pidió compilar (-includeSwitch sin -skipBuildModels) y este parámetro llega
    vacío, el script avisa al principio y se detiene después de la importación, antes
    del switch (ver DESCRIPTION).

.PARAMETER MaxParallelism
    Grado de paralelismo que recibe Import-D365Bacpac. Por defecto 8.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac'

    Importa el bacpac dejando la base intermedia al costado, sin tocar la AxDB activa.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac' `
                           -includeSwitch `
                           -modelsToBuild 'Axxon 365*'

    Importa y pone la base en producción: switch, compilación de todos los módulos no
    binarios que empiecen con 'Axxon 365', arranque de servicios y DB sync.

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac' -includeSwitch -skipBuildModels

    Importa y pone la base en producción sin compilar. Es la forma correcta de saltear
    la compilación: omitir -modelsToBuild NO equivale a esto, detiene el proceso antes
    del switch (ver DESCRIPTION).

.EXAMPLE
    .\SQL-ImportBacpac.ps1 -rutaBacpac "$(BacpacFullPath)" `
                           -includeSwitch `
                           -skipCheckGitRepoUpdated `
                           -tablesToClean 'DOCUHISTORY,BATCHJOBHISTORY,*Staging' `
                           -tablesToExclude 'dbo.AXXTAXFILEPARAMETERS' `
                           -modelsToBuild 'Axxon 365*,DevAx*'

    Forma en la que lo invoca el pipeline Migrate-DB: listas en CSV, provenientes del
    JSON de configuración.

.LINK
    SQL-ExportBacpac.ps1

.LINK
    SQL-CleanBacpac.ps1

.LINK
    SQL-ImportBacpacSqlPackage.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac,

    [switch]$includeSwitch,

    [switch]$includeInstallSqlPackage,

    [switch]$includeUpdateD365foTools,

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

$inicio = Get-Date
$huboError = $false
$pasoActual = 'Validación inicial'

Write-Host "Inicio: $inicio"
Write-Host "Bacpac: $rutaBacpac"

try {
    # Validación temprana: fallar acá evita instalar módulos y limpiar un archivo que
    # no existe.
    if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró el archivo .bacpac indicado: $rutaBacpac")
    }

    $ImportedDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($rutaBacpac)
    Write-Host "Base de datos a crear: $ImportedDatabaseName"

    # -------------------------------------------------------------------------
    # Aviso temprano por -modelsToBuild vacío (ver DESCRIPTION). Se evalúa acá, antes
    # de cualquier trabajo largo, y se vuelve a evaluar después de la importación para
    # abortar. La compilación cuelga de -includeSwitch, así que "se pidió compilar" son
    # las tres condiciones juntas.
    $seVaACompilar = $includeSwitch -and (-not $skipBuildModels)
    $faltaModelsToBuild = $seVaACompilar -and ((ConvertTo-ListaDesdeCsv -Csv $modelsToBuild).Count -eq 0)

    if ($faltaModelsToBuild) {
        # Advertencia, NO error: la importación igual vale la pena y no es destructiva.
        # El operador decide si cancela ahora o si deja que importe y termina a mano.
        Write-PipelineWarning -Message "Se pidió compilar modelos (-includeSwitch sin -skipBuildModels) pero -modelsToBuild llegó vacío, y este script no tiene lista de modelos por defecto. La importación del bacpac SE VA A EJECUTAR igual, pero el proceso SE VA A DETENER ANTES DEL SWITCH de base. Si no querés esperar las horas que tarda la importación, cancelá esta corrida ahora y volvé a lanzarla con -modelsToBuild cargado, o con -skipBuildModels si de verdad no hay que compilar."
    }

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
    # Consultar la galería tarda aunque no haya nada que actualizar, y actualizar tarda
    # minutos. Por eso solo se hace cuando se pide; instalar, en cambio, es obligatorio.
    if ($includeUpdateD365foTools) {
        . "$PSScriptRoot\InstallOrUpdateD365foTools.ps1"
    }
    elseif (-not (Get-Module -ListAvailable -Name d365fo.tools)) {
        Write-Host 'El módulo d365fo.tools no está instalado. Se instala la versión más reciente.'
        Install-Module -Name d365fo.tools
    }
    else {
        Write-Host 'Se usa la versión instalada de d365fo.tools: no se recibió -includeUpdateD365foTools.'
    }
    Write-Host 'Importando el módulo d365fo.tools'
    Import-Module -Name d365fo.tools
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar base destino'
    Start-Phase -Name $pasoActual
    # Va antes de 'Limpiar bacpac' porque esa fase modifica el .bacpac en el lugar: si
    # la importación no puede correr, no tiene sentido tocar el archivo.
    if (@(Get-D365Database -Name $ImportedDatabaseName).Count -gt 0) {
        Complete-Phase -Status Failed
        Write-PipelineError -Message "Ya existe una base de datos '$ImportedDatabaseName' en el servidor, y SqlPackage solo importa sobre una base nueva. Suele ser el resto de una importación anterior que se cortó, así que puede estar incompleta. No es la AxDB en uso. Si se puede descartar, borrala y volvé a ejecutar: ALTER DATABASE [$ImportedDatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$ImportedDatabaseName]; NO se tocó nada: ni el .bacpac, ni la base existente, ni el entorno."

        # 'exit' dentro del try es control de flujo, no una excepción: el catch NO lo
        # intercepta y el finally SÍ corre, así que el resumen de fases sale igual.
        exit 1
    }
    Write-Host "No existe una base '$ImportedDatabaseName' previa: se puede importar."
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

    # NO LLAMAR A Import-D365Bacpac DIRECTAMENTE DESDE ACÁ.
    # Con -ShowOriginalProgress (imprescindible: sin eso una fase de horas no muestra
    # nada), d365fo.tools lanza SqlPackage sin redirigir su salida y no evalúa su código
    # de salida: una importación fallida no lanza excepción. Ese texto va directo a la
    # consola y desde esta sesión no se puede leer. Ejecutando la importación en un
    # powershell.exe hijo con la salida redirigida, SqlPackage hereda la redirección y
    # cada línea llega acá a medida que se escribe: se reenvía al log y se guarda para
    # decidir el resultado.
    $salidaImportacion = New-Object -TypeName System.Collections.Generic.List[string]

    # Con 'Stop', la primera línea de stderr de un comando nativo redirigida con 2>&1 se
    # vuelve un error terminante en Windows PowerShell 5.1.
    $preferenciaPrevia = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File "$PSScriptRoot\SQL-ImportBacpacSqlPackage.ps1" `
            -rutaBacpac $rutaBacpac `
            -nombreBase $ImportedDatabaseName `
            -MaxParallelism $MaxParallelism 2>&1 |
            ForEach-Object {
                $linea = "$_"
                Write-Host $linea
                $salidaImportacion.Add($linea)
            }
        $codigoImportacion = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $preferenciaPrevia
    }

    # Se exige la confirmación explícita de SqlPackage. Que la base exista no prueba
    # nada: una importación cortada a mitad de camino también la deja creada.
    $importacionConfirmada = @($salidaImportacion | Where-Object { $_ -match 'Successfully imported database' }).Count -gt 0
    $erroresSqlPackage = @($salidaImportacion | Where-Object { $_ -match '\*\*\* Error importing database|Error SQL\d+' })

    if ($codigoImportacion -ne 0 -or -not $importacionConfirmada -or $erroresSqlPackage.Count -gt 0) {
        Complete-Phase -Status Failed
        $detalle = if ($erroresSqlPackage.Count -gt 0) { " Primer error informado: $($erroresSqlPackage[0])" } else { '' }
        Write-PipelineError -Message "La importación del bacpac falló: SqlPackage no confirmó 'Successfully imported database' (código de salida del proceso de importación: $codigoImportacion).$detalle La base '$ImportedDatabaseName' puede haber quedado creada e incompleta; hay que borrarla antes de reintentar. NO se tocó nada del entorno destino: no hubo switch, ni compilación, ni DB sync."

        # 'exit' dentro del try es control de flujo, no una excepción: el catch NO lo
        # intercepta y el finally SÍ corre, así que el resumen de fases sale igual.
        exit 1
    }
    Write-Host "Verificación OK: SqlPackage confirmó la importación de '$ImportedDatabaseName'."
    Complete-Phase

    # -------------------------------------------------------------------------
    # Aborto tardío (ver DESCRIPTION). Se corta acá y no antes porque la importación es
    # el objetivo primario y NO es destructiva: la base quedó al costado, en paralelo.
    # Todo lo que sigue SÍ toca el entorno en uso, así que sin lista de modelos se
    # frena antes de empezar a romper nada.
    if ($faltaModelsToBuild) {
        Write-PipelineError -Message "Proceso detenido a propósito antes del switch de base: se pidió compilar pero -modelsToBuild llegó vacío y este script no tiene lista de modelos por defecto. LO QUE SÍ SE HIZO: el bacpac se importó completo y quedó en la base de datos '$ImportedDatabaseName'. LO QUE NO SE HIZO: detener servicios, switch de base, compilar modelos, iniciar servicios y sincronizar la base. ESTADO DEL ENTORNO: intacto y operativo; la AxDB en uso no se tocó y los servicios siguen arriba. PARA TERMINARLO A MANO hace falta, en este orden: switch de base, compilación de modelos y DB sync. Alternativa: volver a lanzar el pipeline con -modelsToBuild cargado."

        # 'exit' dentro del try es control de flujo, no una excepción: el catch NO lo
        # intercepta (así que no se reporta como fase fallida) pero el finally SÍ se
        # ejecuta, de modo que el resumen de fases y los tiempos salen igual.
        exit 1
    }

    # -------------------------------------------------------------------------
    # ORDEN DELIBERADO DE ACÁ EN ADELANTE, NO REORDENAR (ver DESCRIPTION):
    # Detener servicios -> Switch de base -> Compilar modelos -> Iniciar servicios ->
    # Sincronizar DB. El switch deja la base importada en su lugar, la compilación
    # garantiza que no quede metadata sin reflejar en los binarios, y el DB sync
    # concilia la estructura de la base con la versión de los modelos instalados, que
    # es lo que finalmente deja el entorno destino operativo.
    #
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
        # Cada entrada del CSV es un patrón de búsqueda independiente. Llegar acá con la
        # lista vacía es imposible: el aborto tardío de más arriba ya cortó la corrida.
        $patronesDeModelos = ConvertTo-ListaDesdeCsv -Csv $modelsToBuild
        Write-Host "Patrones de búsqueda recibidos: $($patronesDeModelos -join ', ')"

        # CUIDADO CON Get-D365Module: el valor por defecto de -Name es '*', o sea TODOS
        # los módulos instalados, incluidos los de Microsoft. Compilar eso son horas de
        # trabajo inútil. Por eso -Name siempre se pasa explícito y nunca se deja que
        # aplique el default.
        #
        # -ExcludeBinaryModules descarta los módulos desplegados como binarios, que no
        # tienen código fuente para compilar. En este entorno conviven módulos binarios
        # y módulos con fuentes abiertas (WIP), así que este filtro puede devolver cero
        # resultados de forma perfectamente legítima.
        #
        # -InDependencyOrder devuelve los módulos empezando por los que no referencian
        # a ningún otro, que es el orden en el que hay que compilarlos.
        $modulosACompilar = @()
        foreach ($patron in $patronesDeModelos) {
            $encontrados = @(Get-D365Module -Name $patron -ExcludeBinaryModules -InDependencyOrder)
            Write-Host "  Patrón '$patron': $($encontrados.Count) módulo(s)."

            foreach ($modulo in $encontrados) {
                # Un mismo módulo puede coincidir con más de un patrón; se compila una
                # sola vez. -notcontains es case-insensitive, que es lo correcto para
                # nombres de módulo.
                if ($modulosACompilar.ModuleName -notcontains $modulo.ModuleName) {
                    $modulosACompilar += $modulo
                }
            }
        }

        # Se cuenta ANTES de compilar. Un conjunto vacío no es necesariamente un error
        # (puede ser que todos los módulos del patrón estén desplegados como binarios),
        # pero compilar nada en silencio SÍ lo sería: el log quedaría igual al de una
        # compilación exitosa y nadie se enteraría.
        if ($modulosACompilar.Count -eq 0) {
            Write-PipelineWarning -Message "No se encontró ningún módulo para compilar con los patrones '$($patronesDeModelos -join ', ')'. Puede ser correcto si todos esos módulos están desplegados como binarios, porque -ExcludeBinaryModules los descarta por no tener código fuente. Verificá igual que el patrón sea el correcto para este proyecto. No se compiló nada."
            Complete-Phase -Status Skipped
        }
        else {
            Write-Host "Módulos a compilar ($($modulosACompilar.Count), en orden de dependencias): $($modulosACompilar.ModuleName -join ', ')"

            # Invoke-D365ModuleCompile corre SOLO xppc.exe: código fuente -> assemblies
            # + PDB, que es lo único que hace falta en una migración de base. El anterior
            # 'Invoke-D365ProcessModule -ExecuteCompile' llamaba por dentro a
            # Invoke-D365ModuleFullCompile, que además ejecuta labelc.exe (labels) y
            # reportsc.exe (reportes): trabajo desperdiciado en este contexto.
            #
            # NO AGREGAR -XRefGenerationOnly. El ejemplo 5 de la documentación oficial
            # de Invoke-D365ModuleCompile lo incluye y es tentador "completar" el ejemplo,
            # pero ese modificador hace que el compilador SOLO genere metadata de XRef y
            # NO actualice los assemblies ni los PDB, o sea exactamente lo contrario de
            # lo que se busca acá.
            #
            # El pipe funciona porque -Module se enlaza por nombre de propiedad
            # (ValueFromPipelineByPropertyName) y Get-D365Module emite objetos con la
            # propiedad Module.
            #
            # LIMITACIÓN CONOCIDA, IMPORTANTE: con -ShowOriginalProgress, d365fo.tools
            # NO evalúa el código de salida de xppc.exe. Su helper interno Invoke-Process
            # condiciona ese chequeo a "-not $ShowOriginalProgress", así que en este modo
            # una compilación que falla NO lanza excepción y NO hace fallar el step. Es
            # el precio de ver el progreso en vivo en una fase larga, y era igual con el
            # Invoke-D365ProcessModule anterior. Por eso se imprimen abajo las rutas de
            # los logs de xppc: son el único lugar donde queda constancia del resultado
            # real de cada módulo.
            #
            # Verificar el efecto tampoco sirve: los assemblies ya existen de la
            # compilación anterior, así
            # que su presencia no prueba nada, y comparar LastWriteTime por módulo es
            # frágil (un módulo sin cambios puede no reescribirse).
            # TODO: hacer fallar la fase leyendo el XML que xppc deja en
            # $resultado.XmlLogFile. Es la señal confiable: contiene los diagnósticos
            # con su severidad, así que alcanza con parsearlo y cortar si aparece algún
            # nodo de error. Se deja pendiente para no ampliar el alcance de este cambio.
            $resultadosCompilacion = @($modulosACompilar | Invoke-D365ModuleCompile -ShowOriginalProgress)

            # Se consumen los objetos que devuelve el cmdlet en vez de dejarlos caer al
            # stream de salida del script, y se muestran como texto.
            foreach ($resultado in $resultadosCompilacion) {
                Write-Host "  Log de compilación: $($resultado.LogFile)"
            }
            Complete-Phase
        }
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
