<#
.SYNOPSIS
    Instala el módulo d365fo.tools o lo actualiza si hay una versión más reciente en la
    galería.

.DESCRIPTION
    Compara la versión instalada contra la última publicada en PowerShell Gallery y
    actúa en consecuencia: instala si falta, actualiza si quedó atrás, o informa que ya
    está al día. No importa el módulo: eso queda a cargo de quien lo invoca.

    Lo usan los scripts de migración (SQL-ImportBacpac.ps1) con dot-sourcing, como una
    fase previa a importar d365fo.tools.

    No toma parámetros. Requiere conexión a la galería y, según la política de
    instalación de la máquina, ejecutarse como administrador.

.EXAMPLE
    .\InstallOrUpdateD365foTools.ps1

.EXAMPLE
    . "$PSScriptRoot\InstallOrUpdateD365foTools.ps1"
    Import-Module -Name d365fo.tools

    Forma en que lo consumen los scripts del repositorio.

.LINK
    SQL-ImportBacpac.ps1
#>
# Nombre del módulo a verificar
$nombreModulo = "d365fo.tools"

# Obtener información sobre la versión instalada
$moduloInstalado = Get-Module -ListAvailable | Where-Object { $_.Name -eq $nombreModulo }

# Obtener información sobre la versión más reciente disponible
$versionMasReciente = (Find-Module -Name $nombreModulo).Version

if ($null -eq $moduloInstalado) {
    Write-Host -ForegroundColor Yellow "El módulo '$nombreModulo' no está instalado. Se instalará la versión más reciente."
    Install-Module -Name $nombreModulo
} elseif ($moduloInstalado.Version[0] -lt $versionMasReciente) {
    $version = $moduloInstalado.Version[0]
    Write-Host -ForegroundColor Yellow "El módulo '$nombreModulo' está instalado con la versión ($version), pero hay una versión más reciente disponible ($versionMasReciente). Se ejecuta actualización."
    Update-Module -name $nombreModulo -Force
} else {
    Write-Host -ForegroundColor Cyan "El módulo '$nombreModulo' está actualizado a la versión más reciente ($versionMasReciente)."
}
