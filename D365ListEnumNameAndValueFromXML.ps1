<#
.SYNOPSIS
    Lista los valores de un enum X++ a partir de su archivo de metadatos XML.

.DESCRIPTION
    Lee el .xml de un AxEnum del PackagesLocalDirectory y devuelve un objeto por cada
    valor del enum, con su Name y su Value. Los valores sin Value explícito en el XML
    se muestran como "N/A".

    Devuelve objetos, así que se puede encadenar con Where-Object, Sort-Object,
    Export-Csv o Format-Table.

.PARAMETER rutaArchivoXML
    Ruta completa al archivo XML del enum (por ejemplo
    '...\PackagesLocalDirectory\MiModelo\MiModelo\AxEnum\MiEnum.xml').

.EXAMPLE
    .\D365ListEnumNameAndValueFromXML.ps1 -rutaArchivoXML 'C:\Temp\AxEnum\SalesStatus.xml'

    Imprime los valores del enum en consola.

.EXAMPLE
    .\D365ListEnumNameAndValueFromXML.ps1 -rutaArchivoXML 'C:\Temp\AxEnum\SalesStatus.xml' |
        Export-Csv -Path 'C:\Temp\SalesStatus.csv' -NoTypeInformation

    Exporta los valores del enum a un CSV.
#>
# Cargar el XML
param (
    [Parameter(Mandatory=$true)]
    [string]$rutaArchivoXML
)

[xml]$xmlContent = Get-Content -Path $rutaArchivoXML

# Extraer y proyectar Name y Value
$xmlContent.AxEnum.EnumValues.AxEnumValue | ForEach-Object {
    $name = $_.Name
    $value = if ($_.Value) { $_.Value } else { "N/A" }  # Si no tiene Value, se muestra N/A
    [PSCustomObject]@{
        Name  = $name
        Value = $value
    }
}
