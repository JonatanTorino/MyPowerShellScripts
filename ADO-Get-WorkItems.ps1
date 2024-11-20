# Solicitar el ID del commit como parámetro obligatorio
param (
    [Parameter(Mandatory = $true)]
    [string]$CommitId
)

# Importar configuraciones desde un archivo JSON
$configFile = ".\DevOpsAzureREST.config.json"

if (-Not (Test-Path $configFile)) {
    Write-Error "El archivo de configuración $configFile no existe."
    exit
}

$config = Get-Content -Path $configFile | ConvertFrom-Json

# Validar que las claves necesarias están presentes
if (-Not $config.organization -or -Not $config.project -or -Not $config.repositoryId) {
    Write-Error "El archivo de configuración debe contener las claves: organization, project, repositoryId."
    exit
}

# Construir la URL de la API
$url = "https://dev.azure.com/$($config.organization)/$($config.project)/_apis/git/repositories/$($config.repositoryId)/commits/$CommitId/workitems?api-version=7.0"
$url = "https://dev.azure.com/$($config.organization)/$($config.project)/_apis/git/repositories/$($config.repositoryId)/commits/$CommitId/workitems"

# Realizar la solicitud sin especificar credenciales (usa las predeterminadas)
try {
    # $response = Invoke-RestMethod -Uri $url -Method Get -UseDefaultCredentials
    $response = Invoke-WebRequest -Uri $url -Method Get -UseDefaultCredentials

    # Mostrar los Work Items vinculados al commit
    if ($response.value.Count -eq 0) {
        Write-Output "No se encontraron work items asociados al commit $CommitId."
    } else {
        $response.value | ForEach-Object {
            Write-Output "ID: $_.id, Título: $_.fields.'System.Title'"
        }
    }
} catch {
    Write-Error "Error al consultar la API: $_"
}
