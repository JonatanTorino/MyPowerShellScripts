<#
.SYNOPSIS
    Borra recursivamente todas las carpetas vacías que cuelgan de una ruta.

.DESCRIPTION
    Recorre el árbol de abajo hacia arriba, de modo que una carpeta que queda vacía
    porque se borraron sus subcarpetas también se elimina en la misma pasada.

    Por defecto los archivos ocultos (thumbs.db, desktop.ini y similares) NO cuentan
    como contenido: una carpeta que solo los tenga se considera vacía y se borra junto
    con ellos. Con -removeHiddenFiles $false esas carpetas se conservan.

    ES DESTRUCTIVO. Conviene hacer una pasada con -whatIf $true antes de la definitiva.

.PARAMETER folderPath
    Carpeta raíz a partir de la cual se busca.

.PARAMETER whatIf
    Con $true solo informa qué carpetas se borrarían, sin borrar nada. Por defecto
    $false.

.PARAMETER removeHiddenFiles
    Con $true (valor por defecto) los archivos ocultos no impiden que una carpeta se
    considere vacía y se borran con ella. Con $false, una carpeta con archivos ocultos
    se conserva.

.EXAMPLE
    .\DeleteEmptyFolder.ps1 -folderPath 'D:\Archivo' -whatIf $true

    Simula la limpieza y lista las carpetas que se borrarían.

.EXAMPLE
    .\DeleteEmptyFolder.ps1 -folderPath 'D:\Archivo'

    Borra las carpetas vacías, incluidas las que solo tienen archivos ocultos.
#>
param (
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateNotNullOrEmpty()]$folderPath,

    # Set to true to test the script
    [bool]
    [ValidateNotNullOrEmpty()]$whatIf = $false,
        
    # Remove hidden files, like thumbs.db
    $removeHiddenFiles = $true
)

# Get hidden files or not. Depending on removeHiddenFiles setting
$getHiddelFiles = !$removeHiddenFiles
# Remove empty directories locally
Function DeleteEmptyFoldersAndSubFolders($path) 
{
    # Go through each subfolder, 
    Foreach ($subFolder in Get-ChildItem -Force -Literal $path -Directory) 
    {
        # Call the function recursively
        DeleteEmptyFoldersAndSubFolders -path $subFolder.FullName
    }
    # Get all child items
    $subItems = Get-ChildItem -Force:$getHiddelFiles -LiteralPath $path
    # If there are no items, then we can delete the folder
    # Exluce folder: If (($subItems -eq $null) -and (-Not($path.contains("DfsrPrivate")))) 
    If ($null -eq $subItems) 
    {
        Write-Host "Removing empty folder '${path}'"
        Remove-Item -Force -Recurse:$removeHiddenFiles -LiteralPath $Path -WhatIf:$whatIf
    }
}
# Run the script
DeleteEmptyFoldersAndSubFolders -path $folderPath