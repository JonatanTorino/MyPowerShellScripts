param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac
    ,
    [string[]]$tables
    ,
    [string[]]$excludeTables
)

if (-not (Test-Path -Path $rutaBacpac -PathType Leaf)) {
    throw "El archivo bacpac no existe: $rutaBacpac"
}

# Guarda la marca de tiempo de inicio
$inicio = Get-Date
Write-Information "Inicio: $inicio" -InformationAction Continue
Write-Information -ForegroundColor Yellow "Limpiando el bacpac $rutaBacpac" -InformationAction Continue

# Si no se pasan tablas por parámetro, usar lista por defecto
#if (-not $tables -or $tables.Count -eq 0) {
#    [string[]] $tables = @(
#        "DOCUHISTORY", "EVENTCUD", "DMFSTAGINGLOGDETAILS",
#        "SYSEXCEPTIONTABLE", "SYSENCRYPTIONLOG", "SMMTransLog",
#        "BATCH", "BATCHCONSTRAINTS", "BATCHCONSTRAINTSHISTORY", 
#        "BATCHHISTORY", "BATCHJOB", "BATCHJOBALERTS", "BATCHJOBHISTORY",
#        "DEVAXCMMRTSLOGTABLE", "FBMPRICEDISCTABLEINTERFACE",
#        "AXXDOCEINVOICELOG", "AxxTaxFile*", "*Staging"
#    )
#}

# Si no se pasan tablas a excluir, usar lista por defecto
#if (-not $excludeTables -or $excludeTables.Count -eq 0) {
#    [string[]] $excludeTables = @("dbo.AXXTAXFILEPARAMETERS", "dbo.OTRAS_TABLAS")
#}

# Obtener tablas desde bacpac
$tablesToClear = Get-D365BacpacTable -Path $rutaBacpac -Table $tables
$tablesToClear = $tablesToClear | Where-Object { $_.Name -notin $excludeTables }

if ($tablesToClear.Length -gt 0) {
    Write-Information -ForegroundColor Yellow "Tablas a limpiar:" -InformationAction Continue
    $tablesToClear
    $sumOriginalSize = ($tablesToClear | Measure-Object OriginalSize -Sum).Sum / 1GB
    $sumOriginalSizeGB = "Total Original Size {0:N2} GB" -f $sumOriginalSize
    Write-Information -ForegroundColor Green $sumOriginalSizeGB -InformationAction Continue

    $tablesToClear = $tablesToClear | Select-Object -ExpandProperty Name

    Write-Information -ForegroundColor Yellow "Ejecutando limpieza..." -InformationAction Continue
    Clear-D365BacpacTableData -Path $rutaBacpac -Table $tablesToClear -ClearFromSource
}
else {
    Write-Information -ForegroundColor Yellow "No se encontraron tablas para limpiar, posiblemente el bacpac ya está limpio." -InformationAction Continue
}

$fin = Get-Date
Write-Information "Inicio: $inicio" -InformationAction Continue
Write-Information "Final: $fin" -InformationAction Continue
$tiempoTranscurrido = $fin - $inicio
Write-Information -ForegroundColor Green "Tiempo limpieza bacpac transcurrido: $tiempoTranscurrido" -InformationAction Continue