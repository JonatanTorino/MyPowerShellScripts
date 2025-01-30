# Guía de Uso del Script para Instalar PowerShell 7.5.0

Este script está diseñado para descargar e instalar PowerShell 7.5.0 en tu sistema. A continuación, se explica cómo funciona, qué parámetros puedes usar y cómo invocar el script.

## ¿Qué Hace el Script?

1. **Descarga PowerShell 7.5.0**: El script verifica si el archivo de instalación ya existe en tu computadora. Si no existe, lo descarga desde la web.
2. **Instala PowerShell**: Una vez descargado, el script ejecuta el instalador de PowerShell 7.5.0.
3. **Manejo de Errores**: Si hay algún problema durante la descarga o la instalación, el script te informará sobre el error.
4. **Registro de Instalación**: Crea un archivo de registro que contiene información sobre la instalación, lo que puede ser útil para solucionar problemas.

## Parámetros del Script

El script acepta dos parámetros que puedes ajustar según tus necesidades:

- **`-architecture`**: Este parámetro te permite especificar la arquitectura de tu sistema. Puede ser:
  - `"x"`: Para sistemas de 64 bits (por defecto).
  - `"arm"`: Para sistemas basados en ARM.

- **`-silent`**: Este parámetro indica si deseas realizar una instalación silenciosa (sin mostrar ventanas de instalación). Puede ser:
  - `true`: Realiza la instalación sin mostrar mensajes (por defecto).
  - `false`: Muestra la instalación de forma interactiva con un Wizard el que tambièn permite la desinstalación.

## Cómo Invocar el Script

Para ejecutar el script, abre PowerShell y navega hasta la carpeta donde se encuentra el archivo. Luego, puedes usar uno de los siguientes comandos:

1. **Instalación Silenciosa (por defecto)**:
   ```powershell
   .\InstallPowerShell_V_7.5.0.ps1
   ```

2. **Instalación Silenciosa para Arquitectura ARM**:
   ```powershell
   .\InstallPowerShell_V_7.5.0.ps1 -architecture "arm"
   ```

3. **Instalación Interactiva**:
   ```powershell
   .\InstallPowerShell_V_7.5.0.ps1 -silent $false
   ```

4. **Instalación Interactiva para Arquitectura ARM**:
   ```powershell
   .\InstallPowerShell_V_7.5.0.ps1 -architecture "arm" -silent $false
   ```

## Conclusión

Este script es una herramienta útil para instalar PowerShell 7.5.0 de manera rápida y sencilla. 
Se puede personalizar la instalación según tu sistema y preferencias utilizando los parámetros disponibles.