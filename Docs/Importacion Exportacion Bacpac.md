# Guía de Exportación e Importación de Bases de Datos entre Entornos

## Prerequisitos
- Tener instalado [FO365Tools](https://github.com/d365collaborative/d365fo.tools)
- Tener Acceso a Microsoft Dynamics Lifecycle Services (LCS) / One Drive
- Permisos de administrador
- PowerShell

## 1. Exportación de Base de Datos (Entorno A)

### 1.1 Preparación Inicial
1. Clone el repositorio [MypowerShellScripts](https://github.com/JonatanTorino/MyPowerShellScripts): 

- ```powershell
    git clone https://github.com/JonatanTorino/MyPowerShellScripts
![alt text](image-1.png)


### 1.2 Generación del Archivo .bacpac
1. Abra PowerShell como administrador
2. Navegue al directorio del repositorio clonado:

`cd C:\Users\nameUser\Desktop\MyPowerShellScripts`

3. Ejecutar script 
   - ```powershell
        SQL-ExportBacpac.ps1
   - El backup se generará en: `J:\MSSQL_BACKUP\AxDB-Entorno-FechaYYYYmmdd-hhmm.bacpac`

A tener en cuenta:
-  El script se encarga de crear la ruta de destino si no existe
-  Se generara temporalmente el archivo en la ruta: `J:\bacpacBackup\locpos00511112024.bacpac`

### 1.3 Carga del back up en LCS
1. Acceda a Microsoft Dynamics Lifecycle Services (LCS) https://lcs.dynamics.com/v2/AssetLibrary/1278705
2. Suba el archivo bacpac a la Asset Library
3. Configure los permisos necesarios

![alt text](image-14.png)

## 2. Importación de Base de Datos (Entorno B)

### 2.1 Preparación
1. Descargue los archivos desde LCS
2. Realice un backup de la base de datos AxDB existente (si aplica)
![alt text](image-15.png)
### 2.2 Restauración del Bacpac Exportado en el Entorno B
1. Ejecute el comando de importación (el nombre utilizado para la base de datos sera GOLDEN (tener en cuenta que el nombre es solo demostrativo,esto puede ser modificado de acuerdo a sus necesidades),tenerlo presente ya que este nombre lo verá a continuación en varias partes):

- ```powershell
    Import-D365Bacpac -BacpacFile "C:\RutaDescarga\AxDB.bacpac" -ImportModeTier1 -NewDatabaseName GOLDEN
2. Monitoree la creación en la ruta física (ejemplo: `G:\MSSQL_DATA\GOLDEN`)

### 2.3 Activación de la Nueva Base de Datos
1. Al momento de realizar el switch se crea una BD llamada AxDB_Original donde se guardaran los registros de AxDB. Por esta razón es importante eliminarla en caso de que existiera ejecutando el siguiente comando:
- ```powershell
    Remove-D365Database -DatabaseName "AxDB_original" 
2. Ejecutar el switch:
- ```powershell
    Switch-D365ActiveDatabase -SourceDatabaseName GOLDEN
### 2.4 Verificación
Para verificar la configuración:
1. Abra SQL Server Management Studio
2. Seleccione la base de datos AxDB
3. Propiedades > Files
4. Verifique las rutas físicas y lógicas