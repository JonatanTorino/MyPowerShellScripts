<#
.SYNOPSIS
    Reemplaza la licencia de los modelos propios en un entorno D365FO Tier 1: borra los
    códigos de licencia anteriores e importa el archivo de licencia nuevo.

.DESCRIPTION
    Corre cuatro pasos contra la AxDB local, con sqlcmd y el usuario axdbadmin:
    1. Lista los IDs de los códigos de licencia que empiezan con 'Axx' y los de
       TaxxonExchDiffMgmLicenseCode, para dejar constancia en el log.
    2. Borra esos registros de SYSCONFIG y de LICENSECODEIDTABLE.
    3. Borra las claves de configuración asociadas de CONFIGKEYIDTABLE.
    4. Importa el archivo de licencia con Microsoft.Dynamics.AX.Deployment.Setup.exe y
       reinicia IIS.

    OJO: los prefijos de licencia ('Axx%' y 'TaxxonExchDiffMgmLicenseCode%') están
    escritos dentro de las consultas SQL del script. Para otro cliente hay que
    ajustarlos ahí.

    Es una operación DESTRUCTIVA sobre la AxDB: borra registros de licencia antes de
    importar los nuevos. Conviene tener un backup (SQL-BackupDB.ps1) antes de correrlo.

    Requiere ejecutarse en el servidor del entorno, como administrador, con sqlcmd
    disponible y con $env:SERVICEDRIVE apuntando al disco de AosService.

.PARAMETER SqlPassword
    Contraseña del usuario axdbadmin de la instancia local de SQL Server. Obligatoria.

.PARAMETER LicenseFile
    Ruta completa al archivo de licencia a importar. Obligatoria.

.EXAMPLE
    .\D365FO-ApplyLicense.ps1 -SqlPassword '********' -LicenseFile 'C:\Temp\Licencia.txt'

.LINK
    SQL-BackupDB.ps1
#>
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
