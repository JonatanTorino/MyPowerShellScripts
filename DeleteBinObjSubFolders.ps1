<#
.SYNOPSIS
    Borra recursivamente todas las carpetas 'bin' y 'obj' que cuelgan de una ruta.

.DESCRIPTION
    Atajo sobre DeleteSubFolders.ps1: lo invoca dos veces, una para 'bin' y otra para
    'obj'. Sirve para limpiar los artefactos de compilación de un repositorio antes de
    un build limpio o de medir su tamaño real.

    ES DESTRUCTIVO Y NO PIDE CONFIRMACIÓN. Verificar la ruta antes de ejecutarlo.

.PARAMETER path
    Carpeta raíz a partir de la cual se busca. La búsqueda es recursiva e incluye
    carpetas ocultas.

.EXAMPLE
    .\DeleteBinObjSubFolders.ps1 -path 'C:\Repos\MiSolucion'

.LINK
    DeleteSubFolders.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateNotNullOrEmpty()]$path
)

$mypath = $MyInvocation.MyCommand.Path
$workinFolder = Split-Path $mypath -Parent

# Get-ChildItem -Path $path -Recurse -Force -Directory -Include 'bin', 'obj' | Remove-Item -Recurse -Confirm:$false -Force

& $workinFolder\DeleteSubFolders.ps1 $path 'bin'
& $workinFolder\DeleteSubFolders.ps1 $path 'obj'