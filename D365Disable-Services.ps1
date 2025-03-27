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