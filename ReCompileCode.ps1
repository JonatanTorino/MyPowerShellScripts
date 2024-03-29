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
