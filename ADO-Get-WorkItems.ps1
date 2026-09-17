<#
.SYNOPSIS
    Lista los work items vinculados a una pull request de Azure DevOps, con su ID y su
    título.

.DESCRIPTION
    Consulta la API REST de Azure DevOps (api-version 7.0) y, por cada work item
    asociado a la pull request, resuelve su título. El resultado se muestra en la
    consola o en una ventana Out-GridView.

    La organización, el proyecto, el repositorio y el PAT se leen del archivo JSON
    indicado en -ConfigFilePath, que por defecto es DevOpsAzureREST.config.json en el
    mismo directorio que este script. El archivo debe tener las claves organization,
    project, repositoryId y personalAccessToken.

    EL PAT DEBE VENIR DE UNA VARIABLE DE ENTORNO. Si personalAccessToken tiene la forma
    "${env:NOMBRE_VARIABLE}", el valor se resuelve desde esa variable de entorno; si se
    deja el token en texto plano el script funciona igual pero emite una advertencia.
    El PAT necesita permisos de lectura sobre Code y Work Items, y no debe estar
    vencido (se administra en https://dev.azure.com/[organizacion]/_usersSettings/tokens).

.PARAMETER pullRequestId
    ID de la pull request cuyos work items se quieren listar.

.PARAMETER consolePrint
    Muestra el resultado como tabla en la consola (valor por defecto). Con
    -consolePrint:$false se abre una ventana Out-GridView.

.PARAMETER ConfigFilePath
    Ruta del archivo JSON de configuración. Por defecto,
    DevOpsAzureREST.config.json junto a este script.

.EXAMPLE
    .\ADO-Get-WorkItems.ps1 -pullRequestId 1234

    Imprime en consola los work items vinculados a la PR 1234.

.EXAMPLE
    .\ADO-Get-WorkItems.ps1 -pullRequestId 1234 -consolePrint:$false

    Abre los resultados en una cuadrícula interactiva.

.EXAMPLE
    .\ADO-Get-WorkItems.ps1 -pullRequestId 1234 -ConfigFilePath 'C:\Config\OtroProyecto.json'

    Usa la configuración de otra organización o repositorio.
#>

# Solicitar el ID de la pull request como parámetro obligatorio
[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$pullRequestId,
	#parametro para tipos de impresion,en true para consola y false para ventana GridView
	[switch]$consolePrint = $true,

	[Parameter(Mandatory = $false)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$ConfigFilePath = (Join-Path $PSScriptRoot "DevOpsAzureREST.config.json")
)

# Importar configuraciones desde un archivo JSON (incluye PAT)
if (-not (Test-Path $ConfigFilePath)) {
	Write-Error "El archivo de configuración $ConfigFilePath no existe."
	exit
}

$config = Get-Content -Path $ConfigFilePath | ConvertFrom-Json

# Validar que las claves necesarias estén presentes
if (-not $config.organization -or -not $config.project -or -not $config.repositoryId -or -not $config.personalAccessToken) {
	Write-Error "El archivo de configuración debe contener las claves: organization, project, repositoryId, personalAccessToken."
	exit
}

# Expand environment variables in PAT if pattern ${env:VAR} exists
$pat = $config.personalAccessToken
if ($pat -match '\$\{env:(\w+)\}') {
	$envVarName = $Matches[1]
	$envValue = [Environment]::GetEnvironmentVariable($envVarName)
	if (-not $envValue) {
		throw "Environment variable '$envVarName' is not defined"
	}
	$pat = $envValue
	Write-Host "PAT loaded from environment variable: $envVarName" -ForegroundColor Green
}
else {
	Write-Warning "PAT detected as plain text in config.json. Consider using environment variables."
}

# Construir la URL base de la API
$baseUrl = "https://dev.azure.com/$($config.organization)/$($config.project)/_apis/git/repositories/$($config.repositoryId)"

# Construir la URL para obtener los work items de la pull request
$url = "$baseUrl/pullrequests/$pullRequestId/workitems?api-version=7.0"

# Codificar el PAT en Base64
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($pat)"))

# Establecer la cabecera de autorización
$headers = @{
	"Authorization" = "Basic $base64Auth"
}

try {
	
	# Obtener los work items
	$response = Invoke-WebRequest -Uri $url -Method Get -Headers $headers | ConvertFrom-Json
	# Write-Host "Response: $($response)"
	[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

	# Crear un objeto personalizado para cada work item
	$workItemsWithTitles = foreach ($workItem in $response.value) {
		$workItemDetailsUrl = $workItem.url
		$workItemDetails = Invoke-WebRequest -Uri $workItemDetailsUrl -Method Get -Headers $headers | ConvertFrom-Json
		[PSCustomObject]@{
			Id    = $workItem.id
			Title = $workItemDetails.fields.'System.Title'
		}
	}
	if ($consolePrint) {
				
		$workItemsWithTitles | Format-Table -AutoSize
	}
	else {
		
		# Mostrar los resultados en una cuadrícula interactiva
		$workItemsWithTitles | Out-GridView -Title "Work Items"
	}
}
catch {
	Write-Error "Error al consultar la API: $_"
    
}
