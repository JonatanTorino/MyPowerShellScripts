<#
.SYNOPSIS
    Aplica un paquete deployable de actualización de D365FO con AXUpdateInstaller:
    arma la topología, genera el runbook y lo importa.

.DESCRIPTION
    Pide por consola la carpeta donde está descomprimido el paquete de actualización y,
    si encuentra ahí DefaultTopologyData.xml:
    1. Obtiene los service models instalados con "AXUpdateInstaller.exe list".
    2. Reescribe el nodo ServiceModelList de DefaultTopologyData.xml con esa lista, para
       que la topología refleje la máquina real y no la del paquete.
    3. Genera el runbook con el ID "<NOMBRE_DE_MAQUINA>-runbook".
    4. Importa el runbook.

    LA EJECUCIÓN DEL RUNBOOK NO SE HACE ACÁ: la línea "execute" está comentada a
    propósito, para poder revisar el runbook importado antes de aplicarlo. Una vez
    validado, se ejecuta a mano desde la carpeta del paquete:
        .\AXUpdateInstaller.exe execute -runbookid=<MAQUINA>-runbook

    No toma parámetros: la ruta se ingresa de forma interactiva. Requiere ejecutarse en
    el servidor del entorno, como administrador.

    OJO — EFECTO SECUNDARIO: hace Set-Location a la carpeta del paquete y no restaura
    el directorio anterior.

.EXAMPLE
    .\D365UpdateVersion.ps1

    Solicita la ruta (por ejemplo C:\Axxon\SU.10.0.38) y deja el runbook importado y
    listo para ejecutar.
#>
# Definir variables
$extractedFolderPath = Read-Host -Prompt "Por favor, ingrese la ruta donde se encuentra el archivo (por ejemplo, C:\Axxon\SU.10.0.38)"
$runbookID = "$env:COMPUTERNAME-runbook"
$defaultTopologyPath = $extractedFolderPath + "\DefaultTopologyData.xml"
$AXUpdateInstaller = $extractedFolderPath + "\AXUpdateInstaller.exe"

# Preguntar si el archivo existe
if (Test-Path $extractedFolderPath -PathType Container) {
    Write-Host "La carpeta existe en la ruta especificada."

    
    if (Test-Path $defaultTopologyPath -PathType Leaf) {
        
        Set-Location $extractedFolderPath
        # Obtener la lista de servicios usando el comando AXUpdateInstaller.exe list
        $servicesList = & $AXUpdateInstaller list | Select-String "Version:"

        # Obtener solo los nombres de los servicios
        $serviceNames = $servicesList -replace '\s+Version:.*$', '' -replace '^\s+', ''

        #Actualiza el archivo DefaultTopology
        [xml]$xml = Get-Content $defaultTopologyPath
        $serviceModelList = $xml.SelectSingleNode("//ServiceModelList")
        $serviceModelList.RemoveAll()

        $serviceNames | ForEach-Object {
            $elementString = $xml.CreateElement('string')
            $elementString.InnerText = $_
            $serviceModelList.AppendChild($elementString)
        }
        $xml.Save($defaultTopologyPath)

        # Generar el runbook a partir del Topology
        Start-Process -FilePath $AXUpdateInstaller -ArgumentList "generate -runbookid=$runbookID -topologyfile=$defaultTopologyPath -servicemodelfile=DefaultServiceModelData.xml -runbookfile=$runbookID.xml" -Wait

        # Instalar el paquete
        Start-Process -FilePath $AXUpdateInstaller -ArgumentList "import -runbookfile=$runbookID.xml" -Wait

        #Ejecutar
        #Start-Process -FilePath $AXUpdateInstaller -ArgumentList "execute -runbookid=$runbookID" 
    }
    else {
        Write-Host "El archivo no existe dentro de la carpeta"
    }
}
else {
    Write-Host "La carpeta no existe en la ruta especificada. Verifica la ruta y vuelve a ejecutar el script."
}