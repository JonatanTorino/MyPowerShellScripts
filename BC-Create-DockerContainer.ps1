#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Crea un contenedor Docker de Business Central OnPrem con BcContainerHelper.

.DESCRIPTION
    Resuelve la URL del artefacto OnPrem más reciente para el país indicado y levanta
    el contenedor con New-BcContainer, autenticación UserPassword y el usuario 'admin'.
    Actualiza además el archivo hosts para poder resolver el contenedor por nombre.

    Requiere el módulo BcContainerHelper instalado y Docker operativo; para eso está
    BC-Install-BcContainerHelper.ps1. Debe ejecutarse como administrador.

.PARAMETER containerName
    Nombre del contenedor a crear. También es el nombre con el que se lo resuelve por
    hosts.

.PARAMETER country
    Localización del artefacto de Business Central. Por defecto 'w1'.

.PARAMETER numericVersionBC
    Versión numérica a instalar (por ejemplo '24.0'). Si se omite, se toma la última
    disponible para el país elegido.

.PARAMETER licenseFile
    Ruta a un archivo de licencia .bclicense o .flf a aplicar sobre el contenedor. Si
    se omite, el contenedor queda con la licencia por defecto del artefacto.

.PARAMETER memoryLimit
    Límite de memoria del contenedor, en gigabytes. Si se omite o es 0, se usa el
    límite por defecto de Docker.

.EXAMPLE
    .\BC-Create-DockerContainer.ps1 -containerName 'bc-dev'

    Crea un contenedor con el último artefacto OnPrem w1.

.EXAMPLE
    .\BC-Create-DockerContainer.ps1 -containerName 'bc-es' -country 'es' -memoryLimit 8

    Crea un contenedor de la localización española con 8 GB de límite de memoria.

.LINK
    BC-Install-BcContainerHelper.ps1
#>

param (
    [Parameter(Mandatory=$true)]
    [string]
    $containerName
    ,
    [ValidateSet('mx', 'nl', 'it', 'in', 'is', 'no', 'us', 'w1', 'se', 'nz', 'ru', 'gb', 'ca', 'ch', 'be', 'at', 'au', 'cz', 'fi', 'fr', 'es', 'de', 'dk')]
    $country = 'w1'
    ,
    [string]
    $numericVersionBC
    ,
    [ValidateScript({Test-Path $_ -PathType 'Leaf'})]
    [System.IO.FileInfo]
    $licenseFile
    ,
    [int]
    $memoryLimit
)

Import-Module BcContainerHelper

$password = 'P@ssw0rd'
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = New-Object pscredential 'admin', $securePassword
$auth = 'UserPassword'
$artifactUrl = Get-BcArtifactUrl -type 'OnPrem' -country $country `
    $(if (-not [string]::IsNullOrEmpty($numericVersionBC)) { -version $numericVersionBC }) `
    -select 'Latest'

New-BcContainer `
    -accept_eula `
    -containerName $containerName `
    -credential $credential `
    -auth $auth `
    -artifactUrl $artifactUrl `
    -updateHosts `
    $(if ($licenseFile -ne $null) { -licenseFile $licenseFile } ) `
    $(if ($memoryLimit -gt 0) { -memoryLimit "${memoryLimit}G" } ) 