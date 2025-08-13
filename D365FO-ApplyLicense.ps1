[CmdletBinding()]
param (
    [Parameter()]
    [string]
    [ValidateNotNullOrEmpty()]  
    $SqlPassword = $(throw "SqlPassword is required")
    ,
    [ValidateNotNullOrEmpty()]  
    [string]$LicenseFile = $(throw "LicenseFile path is required")
)

# PASO 1 - Consultas SELECT (visualizar IDs)
Write-Output "Ejecutando PASO 1 - Consultas SELECT para obtener IDs"
$sqlQueryStep1 = @"
SELECT l.ID 
FROM LICENSECODEIDTABLE l
INNER JOIN sysconfig s ON l.id = s.id
WHERE name LIKE 'Axx%';

SELECT l.ID 
FROM LICENSECODEIDTABLE l
INNER JOIN sysconfig s ON l.id = s.id
WHERE name LIKE 'TaxxonExchDiffMgmLicenseCode%';
"@
sqlcmd -S . -d AxDB -U axdbadmin -P $SqlPassword -Q  $sqlQueryStep1

# PASO 2 y 3 - Eliminación de registros (usando LIKE)
Write-Output "Ejecutando PASO 2 y 3 - Eliminación de registros"
$sqlQueryStep2and3 = @"
DELETE FROM sysconfig 
WHERE id IN (
    SELECT l.ID 
    FROM LICENSECODEIDTABLE l
    INNER JOIN sysconfig s ON l.id = s.id
    WHERE name LIKE 'Axx%' OR name LIKE 'TaxxonExchDiffMgmLicenseCode%'
);

DELETE FROM LICENSECODEIDTABLE 
WHERE name LIKE 'Axx%' 
   OR name LIKE 'TaxxonExchDiffMgmLicenseCode%';

DELETE FROM CONFIGKEYIDTABLE 
WHERE name LIKE '%Axx%' 
   OR name LIKE '%TaxxonExchDiffMgmLicenseCode%';
"@
sqlcmd -S . -d AxDB -U axdbadmin -P $SqlPassword -Q $sqlQueryStep2and3

# PASO 4 - Importar archivo de licencia y reiniciar IIS
Write-Output "Ejecutando PASO 4 - Importación de licencia y reinicio de IIS"
Set-Location $env:SERVICEDRIVE\AosService\PackagesLocalDirectory\bin\
.\Microsoft.Dynamics.AX.Deployment.Setup.exe `
    --setupmode importlicensefile `
    --metadatadir $env:SERVICEDRIVE\AOSService\PackagesLocalDirectory `
    --bindir $env:SERVICEDRIVE\AOSService\PackagesLocalDirectory `
    --sqlserver . --sqldatabase AXDB --sqluser axdbadmin --sqlpwd $SqlPassword `
    --licensefilename $LicenseFile `

# Reiniciar IIS
Write-Output "Reiniciando IIS..."
iisreset
