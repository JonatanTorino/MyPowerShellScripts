<#
.SYNOPSIS
    Recompila los modelos personalizados de un entorno D365FO Tier 1, sincroniza la
    base, despliega los reportes y reinicia los servicios.

.DESCRIPTION
    Tiene dos modos:
    - Sin -OnlyCustom (por defecto): resuelve TODOS los módulos no binarios con modelos
      personalizables (excluyendo los de Microsoft), los compila en orden de
      dependencias, corre un DB sync completo y después despliega los reportes de cada
      modelo.
    - Con -OnlyCustom: hace una compilación completa (código, labels y reportes) solo
      del módulo indicado en -ModuleName y sincroniza y despliega reportes modelo por
      modelo, sin tocar el resto del entorno.

    En ambos casos termina deteniendo el entorno, levantando los servicios de inicio
    automático, vaciando la caché con Invoke-D365DataFlush e imprimiendo el tiempo
    total de ejecución.

    Es una operación larga, de decenas de minutos a horas según la cantidad de modelos.
    Requiere el módulo d365fo.tools y ejecutarse en el servidor del entorno como
    administrador.

.PARAMETER ModuleName
    Módulo a compilar. Solo se usa con -OnlyCustom; en el modo completo se ignora.

.PARAMETER OnlyCustom
    Compila únicamente el módulo indicado en -ModuleName, en lugar de recorrer todos
    los módulos personalizables del entorno.

.EXAMPLE
    .\ReCompileCode.ps1

    Recompila todos los modelos personalizables del entorno y sincroniza la base.

.EXAMPLE
    .\ReCompileCode.ps1 -ModuleName 'MiModulo' -OnlyCustom

    Compila solo MiModulo y sincroniza y despliega reportes de sus modelos.
#>
[CmdletBinding()]
param (
    [string]
    $ModuleName
    ,
    [switch]
    $OnlyCustom = $false
)

Enable-D365Exception
$StartTime = Get-Date
if ($OnlyCustom)
{
    Invoke-D365ModuleFullCompile -Module $ModuleName 

    #Invoke-D365DBSync -ShowOriginalProgress
    #Invoke-D365DbSyncModule -Module "CTM"
    #Invoke-D365DBSyncPartial -SyncList "DirPartyLocation" -Verbose

    foreach ($model in Get-D365Model -CustomizableOnly -ExcludeMicrosoftModels -ExcludeBinaryModels -Name $ModuleName)
    {
        Invoke-D365DbSyncModule -Module $model.Module
        Invoke-D365ProcessModule -Module $model.Module -ExecuteDeployReports 
    }
}
else
{
    #ALL
    $modules = Get-D365Module -ExcludeBinaryModules -InDependencyOrder | Get-D365Model -ExcludeMicrosoftModels -CustomizableOnly | Select-Object -Property Module -Unique
    foreach ($model in $modules)
    {
        Invoke-D365ProcessModule -Module $model.Module -ExecuteCompile 
    }
    Invoke-D365DBSync -ShowOriginalProgress
    foreach ($model in $modules)
    {
        Invoke-D365ProcessModule -Module $model.Module -ExecuteDeployReports 
    }
}

Stop-D365Environment -All
Start-D365EnvironmentV2 -ShowOriginalProgress -OnlyStartTypeAutomatic
Invoke-D365DataFlush -Class SysFlushData

$RunTime = New-TimeSpan -Start $StartTime -End (get-date) 
Write-Host "Execution time was $($RunTime.Hours) hours, $($RunTime.Minutes) minutes, $($RunTime.Seconds) seconds" 
