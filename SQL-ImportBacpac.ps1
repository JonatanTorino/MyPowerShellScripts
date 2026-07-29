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
    - La compilación dejó de usar "Invoke-D365ProcessModule -Module X -ExecuteCompile".
      Ese modificador llama por dentro a Invoke-D365ModuleFullCompile, que ejecuta TRES
      herramientas: xppc.exe (código fuente), labelc.exe (labels) y reportsc.exe
      (reportes). En una migración de base solo hacen falta los binarios, así que
      labels y reportes eran trabajo desperdiciado. Ahora se resuelve la lista de
      módulos con Get-D365Module y se la manda por pipe a Invoke-D365ModuleCompile, que
      corre únicamente xppc.exe y produce los assemblies y los PDB.
      OJO: la fase de compilación NO falla el step si xppc.exe devuelve error. Con
      -ShowOriginalProgress, d365fo.tools saltea su propio chequeo del código de salida
      (ver el comentario en la fase 'Compilar modelos'). Era igual antes de este cambio.
      Para verificar el resultado real hay que mirar los logs de xppc, cuyas rutas se
      imprimen al final de la fase.
    - Se eliminaron los modelos hardcodeados ('DevAx*' y 'FamiliaBercomat') y todo
      fallback a ellos. Este script tiene que servir en cualquier proyecto, y cada
      cliente tiene su propia convención de nombres o directamente ninguna. No hay
      patrón por defecto y NUNCA se cae silenciosamente a '*'.
    - Los módulos se cuentan ANTES de compilar y se listan en el log. Un conjunto vacío
      no se compila en silencio: se registra una advertencia y la fase queda 'Skipped'.

    AVISO TEMPRANO Y ABORTO TARDÍO POR -modelsToBuild VACÍO:
    La importación del bacpac es el objetivo primario, es cara (2-3 horas) pero NO es
    destructiva: la base aterriza en una base paralela. El switch SÍ es destructivo.
    De ahí el tratamiento asimétrico cuando se pidió compilar y -modelsToBuild llegó
    vacío:
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
