<#
.SYNOPSIS
    Borra recursivamente todas las subcarpetas con un nombre determinado que cuelgan de
    una ruta.

.DESCRIPTION
    Busca de forma recursiva, incluyendo carpetas ocultas, las carpetas cuyo nombre
    coincide con -folderToRemove y las elimina con su contenido. Las que no se pueden
    borrar (en uso, sin permisos) se informan como advertencia y no cortan el proceso.

    ES DESTRUCTIVO Y NO PIDE CONFIRMACIÓN. Verificar la ruta antes de ejecutarlo.

.PARAMETER path
    Carpeta raíz a partir de la cual se busca.

.PARAMETER folderToRemove
    Nombre de la carpeta a eliminar. Admite comodines, porque se usa como -Include de
    Get-ChildItem.

.EXAMPLE
    .\DeleteSubFolders.ps1 -path 'C:\Repos\MiSolucion' -folderToRemove 'bin'

.EXAMPLE
    .\DeleteSubFolders.ps1 -path 'C:\Repos\MiSolucion' -folderToRemove 'node_modules'

.LINK
    DeleteBinObjSubFolders.ps1

.LINK
    DeleteEmptyFolder.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateNotNullOrEmpty()]$path,
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateNotNullOrEmpty]$folderToRemove
)

# Get-ChildItem -Path $path -Recurse -Force -Directory -Include $folderToRemove | Remove-Item -Recurse -Confirm:$false -Force
Get-ChildItem -Path $path -Recurse -Force -Directory -Include $folderToRemove -ErrorAction SilentlyContinue |
ForEach-Object {
    if (Test-Path -LiteralPath $_.FullName) {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "No se pudo borrar: $($_.FullName) :: $($_.Exception.Message)"
        }
    }
}