<#
.SYNOPSIS
    Verifica que un repositorio Git local no tenga cambios pendientes y esté al día
    respecto de su rama por defecto en el remoto.

.DESCRIPTION
    Corta la ejecución con una excepción si la rama local quedó atrás respecto del
    remoto. Lo usa SQL-ImportBacpac.ps1 antes de una migración, para no correr una
    versión vieja de los scripts.

    CAMBIOS (2026-07-29):
    - La rama a comparar ya no está hardcodeada como "main". Este repositorio tiene
      "master" como rama por defecto, así que "origin/main" no existe y la comparación
      era siempre incorrecta. Ahora se resuelve la rama por defecto del remoto
      (refs/remotes/origin/HEAD) y se puede forzar con -nombreRama.
    - Las llamadas nativas a git se ejecutan con ErrorActionPreference en 'Continue'.
      git escribe su progreso en stderr y, con la preferencia en 'Stop' que fija el
      script llamador, eso puede convertirse en un error terminante espurio.

    OJO — EFECTO SECUNDARIO: este script hace Set-Location, es decir muta el directorio
    actual del proceso y no lo restaura. Quien lo invoque debe guardar y restaurar su
    propia ubicación (SQL-ImportBacpac.ps1 lo hace).

.PARAMETER rutaRepositorio
    Ruta del repositorio local a verificar.

.PARAMETER nombreRama
    Rama del remoto contra la que comparar. Si se omite, se resuelve la rama por
    defecto de origin y, si no se puede determinar, se cae a 'master'.

.EXAMPLE
    .\CheckGitRepoUpdated.ps1 -rutaRepositorio 'C:\Repos\MyPowerShellScripts'

.EXAMPLE
    .\CheckGitRepoUpdated.ps1 -rutaRepositorio . -nombreRama 'develop'
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaRepositorio,

    [Parameter(Mandatory = $false)]
    [string]$nombreRama
)

# Cambia al directorio del repositorio (ver la advertencia del bloque de ayuda).
Set-Location $rutaRepositorio

# git manda su progreso a stderr; con ErrorActionPreference='Stop' heredado del script
# llamador eso puede transformarse en un error terminante que no corresponde.
$preferenciaPrevia = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

try {
    if ([string]::IsNullOrWhiteSpace($nombreRama)) {
        # Rama por defecto del remoto, p. ej. "refs/remotes/origin/master" -> "master".
        $refPorDefecto = (git symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null)

        if ([string]::IsNullOrWhiteSpace($refPorDefecto)) {
            # El clon puede no tener origin/HEAD (p. ej. un clone --depth 1 de una rama).
            $nombreRama = 'master'
            Write-Host -ForegroundColor Yellow "No se pudo determinar la rama por defecto de origin; se usa '$nombreRama'."
        }
        else {
            $nombreRama = $refPorDefecto.Trim() -replace '^refs/remotes/origin/', ''
        }
    }

    Write-Host "Verificando el repositorio '$rutaRepositorio' contra 'origin/$nombreRama'"

    # Verifica si hay cambios pendientes en la rama local
    if ($null -eq (git status -s)) {
        Write-Host 'El repositorio no tiene cambios pendientes en la rama local.'
    }
    else {
        Write-Host -ForegroundColor Yellow 'El repositorio tiene cambios pendientes en la rama local. Debes confirmarlos o descartarlos si fuese necesario descargar actualizaciones del repositorio remoto.'
        Write-Host 'Repositorio'
        Write-Host "    $rutaRepositorio"
    }

    # Actualiza la información de la rama remota
    git fetch origin $nombreRama

    # Compara la rama local con la rama remota
    $cantidadDiferencias = (git rev-list "HEAD...origin/$nombreRama" --count)
}
finally {
    $ErrorActionPreference = $preferenciaPrevia
}

if ($cantidadDiferencias -eq 0) {
    Write-Host 'El repositorio está actualizado al día.'
}
else {
    Write-Host 'El repositorio no está actualizado. Hay cambios en la rama remota.'
    Write-Host -ForegroundColor Green 'Para actualizar ejecute un git pull'
    throw 'Secuencia cancelada: el repositorio local no está actualizado respecto del remoto.'
}
