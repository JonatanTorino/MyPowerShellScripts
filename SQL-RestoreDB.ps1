<#
.SYNOPSIS
    Restaura un backup .bak en la instancia local de SQL Server, en las rutas que trae
    el propio backup.

.DESCRIPTION
    Restauración simple con Restore-SqlDatabase: no mueve los archivos de datos ni de
    log, así que las carpetas originales del backup tienen que existir en esta máquina.
    Si hay que reubicarlos, usar SQL-ImportBackupDB.ps1.

    SOBRESCRIBE la base destino si ya existe. Requiere el módulo SqlServer y permisos
    de restauración sobre la instancia local.

.PARAMETER BackupFilePath
    Ruta completa al archivo .bak a restaurar.

.PARAMETER Database
    Nombre de la base destino. Por defecto 'AxDB'.

.EXAMPLE
    .\SQL-RestoreDB.ps1 -BackupFilePath 'J:\MSSQL_BACKUP\AxDB.bak'

.EXAMPLE
    .\SQL-RestoreDB.ps1 -BackupFilePath 'J:\MSSQL_BACKUP\AxDB.bak' -Database 'AxDB_Restore'

.LINK
    SQL-BackupDB.ps1

.LINK
    SQL-ImportBackupDB.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $BackupFilePath
    ,
    [Parameter(Mandatory = $true)]
    [string]
    $Database = "AxDB"
)
# Import-Module -Name SQLPS
Import-Module -Name SqlServer

# Configuración
$serverInstance = "localhost"  # Reemplaza con tu nombre de instancia

Restore-SqlDatabase -ServerInstance $serverInstance -Database $Database -BackupFile $BackupFilePath
