<#
.SYNOPSIS
    Ejecuta Import-D365Bacpac en modo Tier 1 mostrando el progreso original de
    SqlPackage. Lo invoca SQL-ImportBacpac.ps1 en un proceso aparte.

.DESCRIPTION
    Importa el módulo d365fo.tools y llama a Import-D365Bacpac -ImportModeTier1 con
    -ShowOriginalProgress. Eso incluye el paso posterior del módulo que ajusta la base
    recién importada para un entorno Tier 1.

    POR QUÉ ES UN SCRIPT APARTE:
    con -ShowOriginalProgress, d365fo.tools lanza SqlPackage sin redirigir su salida,
    así que SqlPackage escribe directo en la consola que hereda. Desde la misma sesión
    de PowerShell ese texto no se puede leer, y d365fo.tools tampoco evalúa el código
    de salida en ese modo. Ejecutado como proceso hijo con la salida redirigida,
    SqlPackage hereda esa redirección: el proceso padre recibe cada línea a medida que
    se escribe y puede decidir si la importación terminó bien por lo que SqlPackage
    informó.

    Este script NO decide si la importación fue exitosa: solo la ejecuta. La decisión
    la toma SQL-ImportBacpac.ps1 leyendo la salida.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1, porque el módulo d365fo.tools requiere 5.1.

.PARAMETER rutaBacpac
    Ruta completa al archivo .bacpac a importar.

.PARAMETER nombreBase
    Nombre de la base de datos que SqlPackage crea con la importación.

.PARAMETER MaxParallelism
    Grado de paralelismo que recibe Import-D365Bacpac. Por defecto 8.

.EXAMPLE
    powershell.exe -NoProfile -File .\SQL-ImportBacpacSqlPackage.ps1 -rutaBacpac 'C:\Temp\AxDB_Backup.bacpac' -nombreBase 'AxDB_Backup'

    Importa el bacpac en la base 'AxDB_Backup' y escribe el progreso de SqlPackage en
    la salida estándar del proceso.

.LINK
    SQL-ImportBacpac.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBacpac,

    [Parameter(Mandatory = $true)]
    [string]$nombreBase,

    [int]$MaxParallelism = 8
)

$ErrorActionPreference = 'Stop'

Import-Module -Name d365fo.tools

Import-D365Bacpac -ImportModeTier1 `
    -BacpacFile $rutaBacpac `
    -NewDatabaseName $nombreBase `
    -MaxParallelism $MaxParallelism `
    -ShowOriginalProgress
