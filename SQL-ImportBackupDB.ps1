<#
.SYNOPSIS
    Restaura un backup .bak en la instancia local de SQL Server reubicando los archivos
    de datos y de log.

.DESCRIPTION
    Restaura el backup sobre la base indicada y mueve el .mdf y el .ldf a las carpetas
    que se pasan por parámetro. Los archivos destino se nombran a partir del nombre del
    .bak: "<nombre del backup>.mdf" y "<nombre del backup>_log.ldf".

    Para reubicar hay que conocer los nombres LÓGICOS de los archivos dentro del
    backup, que no tienen por qué coincidir con los del archivo físico. Se obtienen con:
        Invoke-Sqlcmd -Query "RESTORE FILELISTONLY FROM DISK = '<ruta del .bak>'"

    OJO: la reubicación se aplica siempre. El modificador -RelocateFile hoy solo sirve
    para exigir que se hayan indicado los cuatro parámetros de reubicación; omitirlo NO
    hace una restauración en las rutas originales.

    Para una restauración simple, sin mover archivos, usar SQL-RestoreDB.ps1.

    Requiere el módulo SqlServer y permisos de restauración sobre la instancia local.

.PARAMETER BackupFilePath
    Ruta completa al archivo .bak a restaurar.

.PARAMETER Database
    Nombre de la base destino. Por defecto 'AxDB'.

.PARAMETER RelocateFile
    Exige que se hayan indicado -FilepathData, -FilepathLog, -LogicalDataName y
    -LogicalLogName, y corta con una excepción si falta alguno.

.PARAMETER FilepathData
    Carpeta donde se escribe el archivo de datos (.mdf).

.PARAMETER FilepathLog
    Carpeta donde se escribe el archivo de log (.ldf).

.PARAMETER LogicalDataName
    Nombre lógico del archivo de datos dentro del backup.

.PARAMETER LogicalLogName
    Nombre lógico del archivo de log dentro del backup.

.EXAMPLE
    .\SQL-ImportBackupDB.ps1 -BackupFilePath 'J:\MSSQL_BACKUP\AxDB.bak' `
                             -Database 'AxDB_Restore' `
                             -RelocateFile `
                             -FilepathData 'J:\MSSQL_DATA' `
                             -FilepathLog 'J:\MSSQL_LOG' `
                             -LogicalDataName 'AXDB' `
                             -LogicalLogName 'AXDB_log'

.LINK
    SQL-RestoreDB.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$BackupFilePath
    ,
    [Parameter(Mandatory = $true)]
    [string]$Database = "AxDB"
    ,
    [switch]$RelocateFile = $false
    ,
    [string]$FilepathData
    ,
    [string]$FilepathLog
    ,
    [string]$LogicalDataName
    ,
    [string]$LogicalLogName
)

if ($RelocateFile) {
    if (-not $FilepathData) {
        throw "El parámetro $FilepathData es obligatorio cuando $RelocateFile está activado."
    }
    if (-not $FilepathLog) {
        throw "El parámetro $FilepathLog es obligatorio cuando $RelocateFile está activado."
    }
    if (-not $LogicalDataName) {
        throw "El parámetro $LogicalDataName es obligatorio cuando $RelocateFile está activado."
    }
    if (-not $LogicalLogName) {
        throw "El parámetro $LogicalLogName es obligatorio cuando $RelocateFile está activado."
    }
}

# Import-Module -Name SQLPS
Import-Module -Name SqlServer

# Configuración
$serverInstance = "localhost"  # Reemplaza con tu nombre de instancia

# Obtener el nombre del archivo .bak sin la extensión
$newFileName = [System.IO.Path]::GetFileNameWithoutExtension($BackupFilePath)

# Crear objetos RelocateFile para los archivos de datos y registro
$RelocateData = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile($LogicalDataName, "$FilepathData\$newFileName.mdf")
$RelocateLog = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile($LogicalLogName, "$FilepathLog\${newFileName}_log.ldf")

Restore-SqlDatabase -ServerInstance $serverInstance -Database $Database -BackupFile $BackupFilePath -RelocateFile @($RelocateData, $RelocateLog)
