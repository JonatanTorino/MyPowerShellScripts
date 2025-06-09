<#COTEJAR INFORMACION
Puntos a tener en cuenta para la correcta obtencion de los datos requeridos
1 	
	Asegurarse que se tenga un PAT (Personal Access Token) con los permisos necesarios y que no este Expirado,
	chequear desde https://dev.azure.com/[Proyecto]/_usersSettings/tokens.
	Configurar el PAT con permisos de lectura para: Code y WorkItems
2 
	Tener el archivo Json DevOpsAzureREST.config.json en el mismo directorio donde se ejecuta este Script 
	que es de donde se obtienen las configuraciones para el presente archivo.
	https://dev.azure.com/[organization]/[project]/_git/[repositoryId]
#> 

# Solicitar el ID de la pull request como parámetro obligatorio
param (
	[Parameter(Mandatory = $true)]
	[string]$pullRequestId,	
	#parametro para tipos de impresion,en true para consola y false para ventana GridView
	[switch]$consolePrint = $true
)

# Importar configuraciones desde un archivo JSON (incluye PAT)
$configFile = ".\DevOpsAzureREST.config.json"

if (-not (Test-Path $configFile)) {
	Write-Error "El archivo de configuración $configFile no existe."
	exit
}

$config = Get-Content -Path $configFile | ConvertFrom-Json

# Validar que las claves necesarias estén presentes
if (-not $config.organization -or -not $config.project -or -not $config.repositoryId -or -not $config.personalAccessToken) {
	Write-Error "El archivo de configuración debe contener las claves: organization, project, repositoryId, personalAccessToken."
	exit
}

# Construir la URL base de la API
$baseUrl = "https://dev.azure.com/$($config.organization)/$($config.project)/_apis/git/repositories/$($config.repositoryId)"

# Construir la URL para obtener los work items de la pull request
$url = "$baseUrl/pullrequests/$pullRequestId/workitems?api-version=7.0"

# Codificar el PAT en Base64
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($config.personalAccessToken)"))

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
