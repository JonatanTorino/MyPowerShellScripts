<#
.SYNOPSIS
    Helper de logging por fases para los scripts de migración de base de datos que
    ejecuta Azure DevOps. Se consume con dot-sourcing, no como módulo.

.DESCRIPTION
    Provee cinco funciones (Start-Phase, Complete-Phase, Write-PhaseSummary,
    Write-PipelineError y Write-PipelineWarning) que instrumentan un script largo
    dividiéndolo en fases visibles y medibles, y que al final imprimen una tabla de
    resumen Fase | Duración | Estado.

    En un agente de Azure DevOps emite los comandos de logging oficiales:
      - "##[group]" / "##[endgroup]" crean una sección colapsable en el log del run,
        de modo que una corrida de varias horas deja de ser un muro de texto plano.
      - "##vso[task.logissue type=error]" registra el error como issue del run, que es
        lo que hace que el step aparezca en rojo en el resumen del build.
      - "##vso[task.logissue type=warning]" registra una advertencia como issue del
        run: queda visible en el resumen del build sin hacerlo fallar.

    DEGRADACIÓN FUERA DE AZURE DEVOPS (2026-07-29):
    Los comandos "##[...]" solo los interpreta el agente. Si la variable de entorno
    TF_BUILD no está definida (ejecución manual desde una consola del servidor), se
    emiten encabezados de texto plano en su lugar, para que los mismos scripts sigan
    siendo usables a mano sin ensuciar la salida con directivas crudas.

    ESTADO COMPARTIDO:
    El estado vive en variables de alcance $script:, por lo que el llamador NO tiene
    que enhebrarlo manualmente entre fases. Al hacer dot-sourcing desde otro script,
    tanto las variables como las funciones quedan en el alcance de ese script, así que
    cada ejecución arranca con su propio estado limpio.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), porque los scripts que
    consumen este helper dependen del módulo d365fo.tools, que requiere 5.1. Los
    agentes self-hosted de estos pipelines son siempre Windows; nunca se usa Linux.

.EXAMPLE
    . "$PSScriptRoot\PipelineLogging.ps1"

    Start-Phase -Name 'Importar bacpac'
    Import-D365Bacpac -ImportModeTier1 -BacpacFile $ruta -NewDatabaseName $base
    Complete-Phase

    Write-PhaseSummary

.EXAMPLE
    # Registrar una fase que se saltea por parámetro: igual aparece en el resumen.
    Start-Phase -Name 'Instalar SqlPackage'
    Write-Host 'Se saltea: no se recibió -includeInstallSqlPackage.'
    Complete-Phase -Status Skipped
#>

# Colección de fases ya cerradas. Cada elemento tiene Fase, Duracion y Estado.
$script:PipelineFases = New-Object System.Collections.Generic.List[psobject]

# Fase actualmente abierta (hashtable con Nombre e Inicio) o $null si no hay ninguna.
$script:PipelineFaseActual = $null

function Test-EsAgenteAzureDevOps {
    <#
    .SYNOPSIS
        Indica si el script se está ejecutando dentro de un agente de Azure DevOps.

    .DESCRIPTION
        El agente define TF_BUILD='True' en todos los steps. Es la señal documentada
        para detectar el contexto de pipeline y la que se usa acá para decidir si
        conviene emitir comandos de logging "##[...]" o texto plano.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD))
}

function Start-Phase {
    <#
    .SYNOPSIS
        Abre una fase, la muestra en el log y arranca su cronómetro.

    .DESCRIPTION
        Emite "##[group]<Name>" en Azure DevOps (sección colapsable) o un encabezado
        de texto plano fuera del agente, y guarda la marca de tiempo de inicio.

        Si ya había una fase abierta sin cerrar, la cierra como 'Ok' antes de abrir la
        nueva. Es una defensa contra un Complete-Phase olvidado: evita que se pierda
        una fila del resumen y que se anide un "##[group]" dentro de otro, que Azure
        DevOps no soporta.

    .PARAMETER Name
        Nombre de la fase tal como debe aparecer en el log y en el resumen final.

    .EXAMPLE
        Start-Phase -Name 'Sincronizar DB'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    # Cierre defensivo de una fase previa sin Complete-Phase (ver DESCRIPTION).
    if ($null -ne $script:PipelineFaseActual) {
        Write-Verbose "Se abrió la fase '$Name' con la fase '$($script:PipelineFaseActual.Nombre)' todavía abierta; se cierra como Ok."
        Complete-Phase -Status Ok
    }

    $script:PipelineFaseActual = @{
        Nombre = $Name
        Inicio = Get-Date
    }

    if (Test-EsAgenteAzureDevOps) {
        # El comando debe empezar en la primera columna de la línea para que el agente lo interprete.
        Write-Host "##[group]$Name"
    }
    else {
        Write-Host ''
        Write-Host "=== $Name ===" -ForegroundColor Cyan
    }
}

function Complete-Phase {
    <#
    .SYNOPSIS
        Cierra la fase abierta, calcula su duración y la acumula en el resumen.

    .DESCRIPTION
        Emite "##[endgroup]" en Azure DevOps (o un pie de texto plano fuera del agente)
        y agrega una fila a la colección que después imprime Write-PhaseSummary.

        Está pensada para invocarse desde un bloque finally, de modo que el grupo del
        log se cierre incluso si la fase terminó por una excepción.

        Si se la llama sin una fase abierta NO falla ni agrega una fila fantasma: deja
        una traza por Write-Verbose y retorna. Ese caso es esperable, por ejemplo,
        cuando el catch del script llamador intenta marcar como fallida una fase que ya
        se había cerrado.

    .PARAMETER Status
        Estado con el que se registra la fase: 'Ok' (default), 'Skipped' para una fase
        salteada por parámetro, o 'Failed' cuando terminó por una excepción.

    .EXAMPLE
        Complete-Phase

    .EXAMPLE
        Complete-Phase -Status Skipped
    #>
    [CmdletBinding()]
    param (
        [ValidateSet('Ok', 'Skipped', 'Failed')]
        [string]$Status = 'Ok'
    )

    if ($null -eq $script:PipelineFaseActual) {
        Write-Verbose "Complete-Phase se invocó sin una fase abierta; no hay nada que cerrar."
        return
    }

    $fase = $script:PipelineFaseActual
    # Se limpia antes de escribir para que un fallo al loguear no deje la fase colgada.
    $script:PipelineFaseActual = $null

    $duracion = (Get-Date) - $fase.Inicio

    $script:PipelineFases.Add([pscustomobject]@{
            Fase     = $fase.Nombre
            Duracion = $duracion
            Estado   = $Status
        })

    if (Test-EsAgenteAzureDevOps) {
        Write-Host '##[endgroup]'
    }
    else {
        $color = switch ($Status) {
            'Failed' { 'Red' }
            'Skipped' { 'DarkGray' }
            default { 'Green' }
        }
        Write-Host ("--- Fin '{0}' ({1}) [{2}] ---" -f $fase.Nombre, (Format-DuracionFase $duracion), $Status) -ForegroundColor $color
    }
}

function Format-DuracionFase {
    <#
    .SYNOPSIS
        Formatea un TimeSpan como hh:mm:ss para el log y el resumen.

    .PARAMETER Duracion
        Intervalo a formatear.

    .EXAMPLE
        Format-DuracionFase -Duracion (New-TimeSpan -Minutes 95)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duracion
    )

    # Se usan las horas totales para que una fase de más de 24 horas no se muestre mal.
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Duracion.TotalHours), $Duracion.Minutes, $Duracion.Seconds)
}

function Write-PhaseSummary {
    <#
    .SYNOPSIS
        Imprime la tabla final Fase | Duración | Estado con el total acumulado.

    .DESCRIPTION
        Construye la tabla con cadenas alineadas y Write-Host en lugar de Format-Table
        a propósito: Format-Table escribe en el stream de salida y contaminaría lo que
        devuelve el script llamador.

        Las fases salteadas también aparecen, para que el resumen refleje qué se
        ejecutó y qué no en esa corrida en vez de omitirlo silenciosamente.

    .EXAMPLE
        Write-PhaseSummary
    #>
    [CmdletBinding()]
    param ()

    Write-Host ''

    if ($script:PipelineFases.Count -eq 0) {
        Write-Host 'No se registró ninguna fase.' -ForegroundColor Yellow
        return
    }

    # El ancho de la primera columna se ajusta a la fase de nombre más largo.
    $anchoFase = ($script:PipelineFases | ForEach-Object { $_.Fase.Length } | Measure-Object -Maximum).Maximum
    if ($anchoFase -lt 4) { $anchoFase = 4 }

    $formato = "{0,-$anchoFase} | {1,8} | {2}"
    $separador = ('-' * $anchoFase) + '-+----------+---------'

    Write-Host 'RESUMEN DE FASES' -ForegroundColor Cyan
    Write-Host ($formato -f 'Fase', 'Duración', 'Estado') -ForegroundColor Cyan
    Write-Host $separador -ForegroundColor Cyan

    foreach ($fase in $script:PipelineFases) {
        $color = switch ($fase.Estado) {
            'Failed' { 'Red' }
            'Skipped' { 'DarkGray' }
            default { 'Green' }
        }
        Write-Host ($formato -f $fase.Fase, (Format-DuracionFase $fase.Duracion), $fase.Estado) -ForegroundColor $color
    }

    Write-Host $separador -ForegroundColor Cyan

    $total = [TimeSpan]::Zero
    foreach ($fase in $script:PipelineFases) { $total += $fase.Duracion }
    Write-Host ($formato -f 'TOTAL', (Format-DuracionFase $total), '') -ForegroundColor Magenta
    Write-Host ''
}

function Write-PipelineError {
    <#
    .SYNOPSIS
        Registra un error de forma que Azure DevOps lo reconozca como tal.

    .DESCRIPTION
        Emite "##vso[task.logissue type=error]<mensaje>", que agrega el error al
        resumen del run además de imprimirlo en el log. Fuera del agente cae a
        Write-Host en rojo.

        Ojo: este comando registra el issue pero NO hace fallar el step por sí solo.
        El script llamador tiene que terminar con "exit 1"; si no, el pipeline sigue
        dando verde aunque la operación haya fallado.

    .PARAMETER Message
        Texto del error. Debe ir en una sola línea: el agente corta el comando en el
        primer salto de línea, así que un mensaje multilínea se trunca.

    .EXAMPLE
        Write-PipelineError -Message "Falló la importación del bacpac: $($_.Exception.Message)"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    # Los saltos de línea cortarían el comando de logging: se aplanan a un solo renglón.
    $mensajePlano = ($Message -replace '\r?\n', ' ').Trim()

    if (Test-EsAgenteAzureDevOps) {
        Write-Host "##vso[task.logissue type=error]$mensajePlano"
    }
    else {
        Write-Host "ERROR: $mensajePlano" -ForegroundColor Red
    }
}

function Write-PipelineWarning {
    <#
    .SYNOPSIS
        Registra una advertencia de forma que Azure DevOps la reconozca como tal.

    .DESCRIPTION
        Emite "##vso[task.logissue type=warning]<mensaje>", que agrega la advertencia
        al resumen del run además de imprimirla en el log. Fuera del agente cae a
        Write-Host en amarillo.

        A diferencia de Write-PipelineError, está pensada para condiciones que el
        operador tiene que ver pero que NO justifican cortar la ejecución: por ejemplo
        avisar en el minuto 1 de que la corrida se va a detener más adelante, para que
        pueda cancelarla en vez de descubrirlo tres horas después.

        No usa Write-Warning a propósito: ese cmdlet escribe en el stream de warnings,
        que el agente no convierte en issue del run, así que la advertencia no
        aparecería en el resumen del build.

    .PARAMETER Message
        Texto de la advertencia. Debe ir en una sola línea: el agente corta el comando
        en el primer salto de línea, así que un mensaje multilínea se trunca.

    .EXAMPLE
        Write-PipelineWarning -Message 'No se encontró ningún módulo para compilar.'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    # Los saltos de línea cortarían el comando de logging: se aplanan a un solo renglón.
    $mensajePlano = ($Message -replace '\r?\n', ' ').Trim()

    if (Test-EsAgenteAzureDevOps) {
        Write-Host "##vso[task.logissue type=warning]$mensajePlano"
    }
    else {
        Write-Host "ADVERTENCIA: $mensajePlano" -ForegroundColor Yellow
    }
}

function ConvertTo-ListaDesdeCsv {
    <#
    .SYNOPSIS
        Convierte una cadena separada por comas en un arreglo limpio de strings.

    .DESCRIPTION
        Los pipelines pasan las listas como CSV en un solo [string] (y no como
        [string[]]) para esquivar los problemas de comillas de YAML. Esta función
        centraliza el parseo: separa por coma, recorta espacios y descarta los
        elementos vacíos.

        Una cadena vacía, nula o de solo espacios devuelve un arreglo vacío, que es la
        señal que usan los scripts llamadores para caer a su lista por defecto.

    .PARAMETER Csv
        Cadena separada por comas. Admite vacío o $null.

    .EXAMPLE
        ConvertTo-ListaDesdeCsv -Csv 'DevAx*, FamiliaBercomat'
        # Devuelve @('DevAx*', 'FamiliaBercomat')
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Csv
    )

    if ([string]::IsNullOrWhiteSpace($Csv)) {
        return @()
    }

    return @(
        $Csv -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}
