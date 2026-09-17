#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepara la máquina para levantar contenedores de Business Central: instala
    BcContainerHelper y habilita las características de Windows que hacen falta.

.DESCRIPTION
    Instala el módulo BcContainerHelper si no está presente y habilita las
    características 'containers' y 'Microsoft-Hyper-V' si están deshabilitadas. Cada
    paso es idempotente: si ya está hecho, informa y sigue.

    No toma parámetros. Debe ejecutarse como administrador y puede requerir reinicio,
    porque las características de Windows se habilitan con -NoRestart.

.EXAMPLE
    .\BC-Install-BcContainerHelper.ps1

    Deja la máquina lista para crear contenedores con BC-Create-DockerContainer.ps1.

.LINK
    BC-Create-DockerContainer.ps1
#>

# Función para comprobar e instalar un módulo
function Install-ModuleIfNotPresent {
    param (
        [string]$ModuleName
    )
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "Instalando el módulo $ModuleName..."
        Install-Module $ModuleName -Force
    } else {
        Write-Host "El módulo $ModuleName ya está instalado."
    }
}

# Función para comprobar y habilitar una característica de Windows
function Enable-WindowsFeatureIfNotEnabled {
    param (
        [string]$FeatureName
    )
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName
    if ($feature.State -ne "Enabled") {
        Write-Host "Habilitando la característica $FeatureName..."
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart
    } else {
        Write-Host "La característica $FeatureName ya está habilitada."
    }
}

# Comprobar e instalar BcContainerHelper
Install-ModuleIfNotPresent -ModuleName "BcContainerHelper"

# Comprobar y habilitar la característica de contenedores
Enable-WindowsFeatureIfNotEnabled -FeatureName "containers"

# Comprobar y habilitar la característica de Hyper-V
Enable-WindowsFeatureIfNotEnabled -FeatureName "Microsoft-Hyper-V"

# Ejecutar el Wizard para creación de un contenedor de BC
# New-BcContainerWizard
