<#
.SYNOPSIS
    Genera un backup comprimido de una base de SQL Server local, con un nombre de
    archivo que identifica base, máquina y momento.

.DESCRIPTION
    Arma el nombre del .bak como
    "<Database>-<NOMBRE_DE_MAQUINA>-<yyyyMMdd-HHmm>[_<ExtraDescription>].bak", lo
    imprime en consola y ejecuta Backup-SqlDatabase contra la instancia local con
    compresión activada.

    Incluir máquina y marca de tiempo en el nombre evita pisar backups anteriores y
    permite identificar el origen de un archivo sin abrirlo.

    Requiere el módulo SqlServer y permisos de backup sobre la instancia local.

.PARAMETER ExtraDescription
    Texto opcional que se agrega al final del nombre del archivo. Se le quitan los
    espacios. Sirve para marcar el motivo del backup.

.PARAMETER Database
    Base a respaldar. Por defecto 'AxDB'.

.PARAMETER TargetPath
    Carpeta donde se escribe el .bak. Por defecto 'J:\MSSQL_BACKUP'.

.EXAMPLE
    .\SQL-BackupDB.ps1

    Respalda AxDB en J:\MSSQL_BACKUP.

.EXAMPLE
    .\SQL-BackupDB.ps1 -ExtraDescription 'previo a upgrade' -TargetPath 'D:\Backups'

    Genera AxDB-<maquina>-<fecha>_previoaupgrade.bak en D:\Backups.

.LINK
    SQL-RestoreDB.ps1
#>
[CmdletBinding()]
param (
    [string]
    $ExtraDescription
    ,
    [string]
    $Database = "AxDB"
    ,
    [string]
    $TargetPath = "J:\MSSQL_BACKUP"
)

$backupfile = "$TargetPath\$Database-$env:computername-$(Get-Date -format "yyyyMMdd-HHmm")"
if ([string]::IsNullOrEmpty($ExtraDescription) ){
    $backupfile += ".bak"
}
else {
    $ExtraDescription = $ExtraDescription.Replace(" ", "");
    $backupfile += "_$ExtraDescription.bak"
}
Write-Host -ForegroundColor Green $backupfile
Backup-SqlDatabase -ServerInstance "localhost" -Database $Database -BackupFile $backupfile -CompressionOption On
