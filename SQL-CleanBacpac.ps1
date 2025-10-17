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
Write-Host "Limpiando el bacpac $rutaBacpac" -ForegroundColor Yellow

# Si no se pasan tablas por parámetro, usar lista por defecto
# if (-not $tables -or $tables.Count -eq 0) {
#     [string[]] $tables = @(
#         "DOCUHISTORY", "EVENTCUD", "DMFSTAGINGLOGDETAILS",
#         "SYSEXCEPTIONTABLE", "SYSENCRYPTIONLOG", "SMMTransLog",
#         "BATCH", "BATCHCONSTRAINTS", "BATCHCONSTRAINTSHISTORY", 
#         "BATCHHISTORY", "BATCHJOB", "BATCHJOBALERTS", "BATCHJOBHISTORY",
#         "DEVAXCMMRTSLOGTABLE", "FBMPRICEDISCTABLEINTERFACE",
#         "AXXDOCEINVOICELOG", "AxxTaxFile*", "*Staging"
#     )
# }

# Si no se pasan tablas a excluir, usar lista por defecto
# if (-not $excludeTables -or $excludeTables.Count -eq 0) {
#     [string[]] $excludeTables = @("dbo.AXXTAXFILEPARAMETERS", "dbo.OTRAS_TABLAS")
# }

# Validar que se pasaron tablas
if (-not $tables -or $tables.Count -eq 0) {
    Write-Host "No se especificaron tablas para limpiar. Saltando limpieza." -ForegroundColor Yellow
    return
}

Write-Information "Tablas a buscar: $($tables -join ', ')" -InformationAction Continue
if ($excludeTables -and $excludeTables.Count -gt 0) {
    Write-Information "Tablas a excluir: $($excludeTables -join ', ')" -InformationAction Continue
}

# Obtener tablas desde bacpac
try {
    $tablesToClear = Get-D365BacpacTable -Path $rutaBacpac -Table $tables
    
    # Filtrar tablas excluidas si existen
    if ($excludeTables -and $excludeTables.Count -gt 0) {
        $tablesToClear = $tablesToClear | Where-Object { $_.Name -notin $excludeTables }
    }
}
catch {
    Write-Error "Error al obtener tablas del bacpac: $($_.Exception.Message)"
    throw
}

if ($tablesToClear -and $tablesToClear.Count -gt 0) {
    Write-Host "Tablas a limpiar:" -ForegroundColor Yellow
    $tablesToClear | Format-Table -AutoSize
    
    $sumOriginalSize = ($tablesToClear | Measure-Object OriginalSize -Sum).Sum / 1GB
    $sumOriginalSizeGB = "Total Original Size {0:N2} GB" -f $sumOriginalSize
    Write-Host $sumOriginalSizeGB -ForegroundColor Green

    $tablesToClear = $tablesToClear | Select-Object -ExpandProperty Name

    Write-Host "Ejecutando limpieza..." -ForegroundColor Yellow
    try {
        Clear-D365BacpacTableData -Path $rutaBacpac -Table $tablesToClear -ClearFromSource
        Write-Host "Limpieza completada exitosamente" -ForegroundColor Green
    }
    catch {
        Write-Error "Error durante la limpieza: $($_.Exception.Message)"
        throw
    }
}
else {
    Write-Host "No se encontraron tablas para limpiar, posiblemente el bacpac ya está limpio." -ForegroundColor Yellow
}

$fin = Get-Date
Write-Information "Inicio: $inicio" -InformationAction Continue
Write-Information "Final: $fin" -InformationAction Continue
$tiempoTranscurrido = $fin - $inicio
Write-Host "Tiempo limpieza bacpac transcurrido: $tiempoTranscurrido" -ForegroundColor Green