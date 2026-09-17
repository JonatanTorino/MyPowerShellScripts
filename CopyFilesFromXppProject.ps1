<#
.SYNOPSIS
    Copia a una carpeta destino los archivos XML de los elementos incluidos en un
    proyecto X++ (.rnrproj).

.DESCRIPTION
    Lee el .rnrproj, toma el atributo Include de cada nodo Content (que tiene la forma
    "TipoDeElemento\NombreDelElemento") y copia el .xml correspondiente desde el
    PackagesLocalDirectory del modelo hacia el destino, respetando la carpeta por tipo
    de elemento. Las carpetas que faltan en el destino se crean.

    Sirve para armar el juego de metadatos de un proyecto sin exportar el modelo
    entero. Los elementos que no existan en el modelo se informan como advertencia y
    se saltean.

.PARAMETER ProjectPath
    Ruta completa al archivo de proyecto X++ (.rnrproj) a procesar.

.PARAMETER AosModelPath
    Carpeta del modelo dentro de PackagesLocalDirectory de la que se leen los XML de
    origen (por ejemplo
    'K:\AosService\PackagesLocalDirectory\MiModelo\MiModelo').

.PARAMETER DestinationPath
    Carpeta donde se copian los archivos, agrupados por tipo de elemento.

.EXAMPLE
    .\CopyFilesFromXppProject.ps1 -ProjectPath 'C:\Repos\MiProy\MiProy.rnrproj' `
                                  -AosModelPath 'K:\AosService\PackagesLocalDirectory\MiModelo\MiModelo' `
                                  -DestinationPath 'C:\Temp\Export'
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$ProjectPath,

    [Parameter(Mandatory=$true)]
    [string]$AosModelPath,

    [Parameter(Mandatory=$true)]
    [string]$DestinationPath
)

# Cargar el archivo XML
[xml]$xmlContent = Get-Content -Path $ProjectPath

# Extraer todos los valores del atributo "Include" de los nodos "Content"
$includes = $xmlContent.Project.ItemGroup.Content | ForEach-Object { $_.Include }

# Procesar cada valor "Include"
foreach ($include in $includes) {
    # Separar en carpeta y nombre de archivo
    $parts = $include -split '\\'
    $folderName = $parts[0]
    $fileName = $parts[1] + '.xml'

    # Crear la ruta completa del archivo fuente
    $sourceFilePath = Join-Path -Path $AosModelPath -ChildPath $include
    $sourceFilePath += '.xml'

    # Verificar si el archivo existe
    if (Test-Path -Path $sourceFilePath) {
        # Crear la ruta de destino
        $destinationFolderPath = Join-Path -Path $DestinationPath -ChildPath $folderName
        $destinationFilePath = Join-Path -Path $destinationFolderPath -ChildPath $fileName

        # Verificar si la carpeta de destino existe, si no, crearla
        if (-not (Test-Path -Path $destinationFolderPath)) {
            New-Item -ItemType Directory -Path $destinationFolderPath -Force
        }

        # Copiar el archivo al destino
        Copy-Item -Path $sourceFilePath -Destination $destinationFilePath -Force
        Write-Host "Archivo '$fileName' copiado exitosamente a '$destinationFolderPath'."
    } else {
        Write-Warning "El archivo '$sourceFilePath' no existe y no se copiará."
    }
}

Write-Host "Proceso completado."
