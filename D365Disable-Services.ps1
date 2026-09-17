<#
.SYNOPSIS
    Detiene y deshabilita los servicios de Management Reporter y DMF de un entorno
    D365FO, sin depender de d365fo.tools.

.DESCRIPTION
    Recorre una lista fija de servicios (MR2012ProcessService y el helper SSIS de DMF),
    los detiene y les deja el tipo de inicio en Deshabilitado. Es la alternativa a
    D365Disable-MRyDMF.ps1 para máquinas donde no está instalado d365fo.tools.

    La lista de servicios está en la variable $services al principio del script; para
    agregar o quitar servicios se edita ahí.

    No toma parámetros. Requiere ejecutarse como administrador.

.EXAMPLE
    .\D365Disable-Services.ps1

.LINK
    D365Disable-MRyDMF.ps1
#>
# Lista de servicios a detener y deshabilitar
$services = @(
    "MR2012ProcessService",
    "Microsoft.Dynamics.AX.Framework.Tools.DMF.SSISHelperService.exe"
)

# Función para detener y deshabilitar servicios
function Disable-Service {
    param (
        [string]$serviceName
    )
    
    # Detener el servicio
    Stop-Service -Name $serviceName -Force
    
    # Deshabilitar el servicio
    Set-Service -Name $serviceName -StartupType Disabled
}

# Iterar sobre la lista de servicios y aplicar la función
foreach ($service in $services) {
    Disable-Service -serviceName $service
}