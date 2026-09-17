<#
.SYNOPSIS
    Aliviana un entorno D365FO de desarrollo: deshabilita Management Reporter y DMF, y
    agrega las exclusiones de Windows Defender.

.DESCRIPTION
    Sobre el entorno local, con d365fo.tools:
    - Fija la página de inicio del navegador en la URL del entorno.
    - Detiene Management Reporter y deja sus servicios en inicio Deshabilitado.
    - Detiene DMF y deja sus servicios en inicio Deshabilitado.
    - Agrega las reglas de exclusión de Windows Defender que aceleran la compilación.

    Management Reporter y DMF consumen recursos y llenan el Visor de eventos sin
    aportar nada en una máquina de desarrollo. NO usar en un entorno donde se necesiten
    reportes financieros o importación/exportación de datos.

    No toma parámetros. Requiere el módulo d365fo.tools y ejecutarse como administrador.

.EXAMPLE
    .\D365Disable-MRyDMF.ps1

.LINK
    D365Disable-Services.ps1
#>
Import-Module -Name d365fo.tools

#region Disable services
Write-Host "Setting web browser homepage to the local environment"
Get-D365Url | Set-D365StartPage
Write-Host "Setting Management Reporter to manual startup to reduce churn and Event Log messages"
Stop-D365Environment -FinancialReporter
Get-D365Environment -FinancialReporter | Set-Service -StartupType Disabled
Write-Host "Setting DMF manual startup to reduce churn and Event Log messages"
Stop-D365Environment -DMF
Get-D365Environment -DMF | Set-Service -StartupType Disabled
Write-Host "Setting Windows Defender rules to speed up compilation time"
Add-D365WindowsDefenderRules -Silent
#endregion
