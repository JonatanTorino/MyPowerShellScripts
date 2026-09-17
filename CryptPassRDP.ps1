<#
.SYNOPSIS
    Cifra una contraseña para poder guardarla en un archivo .rdp de Escritorio remoto.

.DESCRIPTION
    Pide la contraseña por consola sin mostrarla, la cifra con ConvertFrom-SecureString
    y escribe el resultado en pantalla, listo para pegarlo en un .rdp como
    "password 51:<texto cifrado>".

    OJO: el cifrado usa DPAPI, así que el texto resultante solo puede descifrarlo el
    MISMO usuario en la MISMA máquina donde se ejecutó este script. No sirve para
    compartir credenciales.

    No toma parámetros; la contraseña se ingresa de forma interactiva.

.EXAMPLE
    .\CryptPassRDP.ps1

    Solicita la clave y devuelve el texto cifrado por consola.
#>
# Obtener la clave en formato de SecureString
$clave = Read-Host -Prompt "Ingrese la clave" -AsSecureString

# Convertir el SecureString en texto cifrado
$claveCifrada = $clave | ConvertFrom-SecureString

# Guardar el texto cifrado en un archivo RDP
# $archivoRDP = "C:\Ruta\Archivo.rdp"
# Set-Content -Path $archivoRDP -Value "password 51:$claveCifrada"
Write-Host $claveCifrada
