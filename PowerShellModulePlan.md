# Plan para Crear un Módulo de PowerShell

Convertir tu colección de scripts en un módulo de PowerShell es una práctica muy recomendable. Centraliza tu código, facilita su distribución y simplifica la gestión de versiones.

Aquí te explico las formas de hacerlo, cómo agrupar tus scripts y cómo funcionaría el proceso de actualización.

### Resumen de Enfoques

Tienes dos enfoques principales:

1.  **Enfoque Manual:** Creas la estructura de carpetas y los archivos de manifiesto (`.psd1`) y módulo (`.psm1`) a mano. Es ideal para empezar y entender cómo funcionan los módulos.
2.  **Enfoque Automatizado (CI/CD):** Creas un pipeline en Azure DevOps o GitHub Actions que, cada vez que actualizas el repositorio (ej. en la rama `main`), automáticamente empaqueta, versiona y publica el módulo en un repositorio de paquetes (como PowerShell Gallery o un feed privado).

---

### 1. ¿Cómo Agrupar los Scripts? (Estructura del Módulo)

Independientemente del enfoque que elijas, la estructura es la misma. Debes crear una carpeta principal para tu módulo. El nombre de esta carpeta será el nombre del módulo. Dentro, colocarás tus scripts y dos archivos especiales:

*   **`[NombreDelModulo].psd1` (Manifiesto del Módulo):** Es un archivo de metadatos. Contiene información como el nombre, la versión, el autor y, lo más importante, las funciones que el módulo "exporta" (hace públicas).
*   **`[NombreDelModulo].psm1` (Módulo de Script):** Este es el "corazón" del módulo. Es un script que se ejecuta cuando importas el módulo. Su trabajo principal es cargar todos tus otros scripts `.ps1` en la sesión.

**Estructura de ejemplo:**

```
C:\Repos\JonatanTorino\MyPowerShellScripts\
│
└─── MyPowerShellScripts\      <-- Carpeta principal del módulo (nombre del módulo)
     │
     ├─── MyPowerShellScripts.psd1  <-- Manifiesto
     ├─── MyPowerShellScripts.psm1  <-- Script principal del módulo
     │
     └─── Scripts\                  <-- (Opcional) Subcarpeta para organizar tus scripts
          │
          ├─── ADO-Get-WorkItems.ps1
          ├─── SQL-BackupDB.ps1
          ├─── D365Disable-Services.ps1
          └─── ... (y todos los demás scripts .ps1)
```

**Contenido del `MyPowerShellScripts.psm1` (ejemplo):**

```powershell
# MyPowerShellScripts.psm1

# Obtener la ruta del directorio actual del script
$PSScriptRoot = $PSScriptRoot

# Cargar todos los scripts de la subcarpeta 'Scripts'
# Asegúrate de que la ruta sea correcta si decides no usar una subcarpeta 'Scripts'
Get-ChildItem -Path "$PSScriptRoot\Scripts\*.ps1" -Recurse | ForEach-Object {
    . $_.FullName
}

# Exportar las funciones que quieres que sean públicas y utilizables por el usuario
# Si no haces esto, las funciones se cargarán pero no serán comandos visibles.
# Esto exportará todas las funciones definidas en los scripts cargados.
Export-ModuleMember -Function (Get-Command -Module $MyInvocation.MyCommand.Name).Name
```

---

### 2. ¿Qué Formas Tengo Para Crearlo?

#### Opción 1: Creación Manual

1.  **Crea la estructura de carpetas** como se describió arriba. Por ejemplo, crea una carpeta llamada `MyPowerShellScripts` dentro de tu repositorio actual.
2.  **Copia tus scripts:** Mueve todos tus archivos `.ps1` a la subcarpeta `MyPowerShellScripts\Scripts\` (o directamente a `MyPowerShellScripts\` si no usas la subcarpeta `Scripts`).
3.  **Crea el manifiesto (`.psd1`)**: Abre una terminal de PowerShell en la carpeta `MyPowerShellScripts` (la carpeta raíz del módulo) y ejecuta:
    ```powershell
    New-ModuleManifest -Path .\MyPowerShellScripts.psd1 -RootModule .\MyPowerShellScripts.psm1 -Author "Jonatan Torino" -Description "Módulo de PowerShell con scripts de administración y desarrollo." -ModuleVersion '1.0.0'
    ```
    Esto creará un archivo de manifiesto con la información básica. Puedes editarlo para añadir más detalles si lo deseas.
4.  **Crea el archivo `.psm1`** con el contenido de ejemplo que te mostré antes para cargar tus scripts. Asegúrate de ajustar la ruta si no usas la subcarpeta `Scripts`.
5.  **Instalación Local (para probar):** Para usarlo, solo necesitas copiar la carpeta `MyPowerShellScripts` completa a una de las carpetas que están en tu `$env:PSModulePath`. Una común es `C:\Users\tu_usuario\Documents\PowerShell\Modules`.
6.  **Uso:** Después de copiarla, abre una nueva terminal de PowerShell y podrás usar los comandos: `Import-Module MyPowerShellScripts`. Las funciones de tus scripts estarán disponibles.

#### Opción 2: Creación Automatizada con CI/CD

Este es el método profesional y escalable.

1.  **Base:** Partes de la misma estructura de carpetas y archivos (`.psd1`, `.psm1`) que en la opción manual.
2.  **Repositorio de Paquetes:** Necesitas un lugar donde publicar tu módulo. Puede ser:
    *   **PowerShell Gallery:** El repositorio público oficial.
    *   **Azure Artifacts:** Un feed de paquetes privado en Azure DevOps (ideal si trabajas en una organización).
    *   **GitHub Packages:** Similar a Azure Artifacts, pero en GitHub.
3.  **Pipeline (GitHub Actions o Azure DevOps):** Creas un flujo de trabajo automatizado que hace lo siguiente:
    *   Se dispara cada vez que haces un `push` a tu rama principal (ej. `main`).
    *   **Incrementa la versión:** Lee el `ModuleVersion` del `.psd1` y lo aumenta (ej. de `1.0.0` a `1.0.1`). Esto es **clave** para las actualizaciones. Hay herramientas como `Invoke-Build` o scripts personalizados para esto.
    *   **(Opcional pero recomendado)** Ejecuta pruebas automáticas con Pester para asegurar que nada se ha roto.
    *   **Publica el módulo:** Usa el comando `Publish-Module` para subir la nueva versión a tu repositorio de paquetes (PowerShell Gallery, Azure Artifacts, etc.). Esto requiere una clave API o credenciales para el repositorio.

---

### 3. ¿Cómo Recibiría Actualizaciones el Módulo?

Esta es la mayor ventaja del enfoque automatizado. El proceso de actualización se basa en la **versión** que defines en el manifiesto (`.psd1`).

1.  **Publicación:** Tu pipeline de CI/CD se encarga de publicar una nueva versión del módulo (ej. `1.0.1`, `1.1.0`) cada vez que fusionas cambios importantes.
2.  **Instalación Inicial:** Un usuario (o tú en otra máquina) instala el módulo por primera vez desde el repositorio que elegiste.
    ```powershell
    # Ejemplo para un feed privado (debes registrar el repositorio primero)
    Register-PSRepository -Name MyPrivateFeed -SourceLocation "https://my.nuget.feed/v3/index.json" -InstallationPolicy Trusted
    Install-Module -Name MyPowerShellScripts -Repository MyPrivateFeed -Scope CurrentUser
    
    # Ejemplo para PowerShell Gallery (ya registrado por defecto)
    Install-Module -Name MyPowerShellScripts -Scope CurrentUser
    ```
3.  **Detección y Actualización:** Cuando quieras actualizar, simplemente ejecutas:
    ```powershell
    Update-Module -Name MyPowerShellScripts
    ```
    PowerShell comparará la versión que tienes instalada con la última versión disponible en el repositorio. Si hay una nueva, la descargará y la instalará.

### Resumen y Próximos Pasos

*   **Para empezar:** Te recomiendo seguir la **Opción 1 (Manual)**. Te ayudará a familiarizarte con la estructura y los conceptos básicos de un módulo.
*   **Para escalar:** Una vez que te sientas cómodo, investiga cómo crear un pipeline simple en GitHub Actions para automatizar la publicación. Este es el estándar de la industria y resuelve completamente el problema de las actualizaciones.
