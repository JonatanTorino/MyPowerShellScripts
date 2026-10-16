<#
.SYNOPSIS
    Restaura un archivo .bak como AxDB en un entorno D365FO Tier 1 y, opcionalmente,
    lo pone en producción haciendo el switch de base, la compilación y el DB sync.

.DESCRIPTION
    Contraparte de SQL-ExportBak.ps1. Orquesta la migración de una base AxDB entre
    entornos de nivel 1 restaurando un backup nativo, en lugar de importar un .bacpac.
    El proceso se divide en fases visibles e independientes, cada una envuelta en un
    grupo colapsable del log de Azure DevOps, y al final imprime una tabla
    Fase | Duración | Estado con lo que se ejecutó y lo que se salteó.

    Fases, en orden: Verificar repo, Instalar d365fo.tools, Verificar base destino,
    Validar backup, Restaurar base, Reconciliar usuarios, Ajustar base al entorno,
    Detener servicios, Switch de base, Compilar modelos, Iniciar servicios,
    Sincronizar DB.

    LA BASE DESTINO NO PUEDE EXISTIR DE ANTEMANO:
    La base se crea con el nombre del .bak sin extensión. Si ya existe (por ejemplo,
    el resto de una restauración anterior que se cortó), el script falla en
    'Verificar base destino' y no la borra: decidir si se descarta es del operador. El
    RESTORE nunca usa WITH REPLACE.

    VALIDACIONES PREVIAS AL RESTORE:
    'Validar backup' lee la cabecera del .bak (un único backup completo, con una
    versión de SQL Server que esta instancia pueda restaurar), calcula a dónde va cada
    archivo y verifica que haya espacio libre en cada volumen. RESTORE recrea los
    archivos con el tamaño que tenían en el origen, así que un disco sin lugar se
    detecta acá y no a mitad de la restauración.

    USUARIOS DEL SERVIDOR DE ORIGEN:
    Un backup trae los usuarios de base con el SID de los logins del servidor de
    origen. Los logins de servicio de D365FO (axdbadmin, axdeployuser, ...) se crean
    al aprovisionar cada VM, así que en este servidor tienen otro SID y los usuarios
    llegan huérfanos. 'Reconciliar usuarios', siempre contra la base restaurada al
    costado y antes del switch:
    - Pasa la propiedad de la base a sa.
    - Remapea cada usuario huérfano que tenga un login homónimo en este servidor
      (ALTER USER ... WITH LOGIN), lo que conserva sus roles y permisos.
    - Informa como advertencia los huérfanos sin login equivalente, como las cuentas
      Windows locales de la VM de origen. No los borra.
    - Crea los usuarios de servicio de D365FO que falten y les asigna sus roles.
    - Falla si axdbadmin, axdeployuser o NT AUTHORITY\NETWORK SERVICE no quedan
      mapeados a un login de este servidor: sin ellos el AOS no levanta.

    AJUSTES AL ENTORNO DESTINO:
    'Ajustar base al entorno' vacía RETAILHARDWAREPROFILE.SECUREMERCHANTPROPERTIES
    (dato cifrado con material del entorno de origen), verifica que
    SYSGLOBALCONFIGURATION tenga BACKENDDB = SQLSERVER y TEMPTABLEINAXDB = 0 (los
    corrige con una advertencia si no) y repuebla los índices full-text de Commerce.
    Además compara con la AxDB actual las opciones de base que un RESTORE puede
    cambiar o traer distintas del origen (recovery model, nivel de compatibilidad,
    aislamiento por snapshot, Service Broker, TRUSTWORTHY): las diferencias se
    informan como advertencia y no se corrigen.

    LA LIMPIEZA DE TABLAS NO SE HACE ACÁ:
    Las tablas de log se vacían en el origen, sobre la copia de staging que arma
    SQL-ExportBak.ps1, antes de generar el .bak.

    Sin -includeSwitch el script se detiene después de ajustar la base: queda al
    costado, en paralelo, y el entorno en uso no se toca. Con -includeSwitch se
    ejecutan además las cinco fases finales, que sí modifican el entorno.

    EL ORDEN DE LAS ÚLTIMAS FASES ES DELIBERADO:
    Detener servicios -> Switch de base -> Compilar modelos -> Iniciar servicios ->
    Sincronizar DB. NO reordenar. El switch va primero porque es lo que deja la base
    restaurada en su lugar; la compilación va después para garantizar que no quede
    ningún cambio de metadata sin reflejar en los binarios; y recién entonces el DB
    sync concilia la estructura de la base con la versión de los modelos instalados.

    QUÉ PASA SI SE PIDIÓ COMPILAR Y -modelsToBuild LLEGA VACÍO:
    Al principio se emite una advertencia y la restauración corre igual, porque no es
    destructiva: la base aterriza al costado. Antes de detener servicios se registra
    un error y se sale con "exit 1": el entorno destino queda intacto y la base
    restaurada queda lista para terminar el trabajo a mano.

    LIMITACIÓN CONOCIDA DE LA FASE 'Compilar modelos':
    esa fase NO hace fallar el step si xppc.exe devuelve error, porque
    -ShowOriginalProgress hace que d365fo.tools saltee su propio chequeo del código de
    salida. Para verificar el resultado real hay que mirar los logs de xppc, cuyas
    rutas se imprimen al final de la fase.

    QUIÉN LEE EL ARCHIVO:
    RESTORE lo ejecuta la cuenta de servicio de SQL Server, no el usuario que corre
    este script. El .bak tiene que estar en una carpeta que esa cuenta pueda leer (el
    pipeline lo copia a J:\MSSQL_BACKUP antes de llamar a este script).

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), porque el módulo d365fo.tools
    requiere 5.1. Las fases de SQL usan System.Data.SqlClient (SqlBakHelpers.ps1).

.PARAMETER rutaBak
    Ruta completa al archivo .bak a restaurar. El nombre del archivo, sin extensión,
    se usa como nombre de la base que se crea.

.PARAMETER includeSwitch
    Ejecuta la puesta en producción de la base restaurada: detiene los servicios,
    elimina AxDB_original si existe, hace el switch de la base activa, compila los
    modelos, levanta los servicios y corre el DB sync. Sin este modificador el script
    solo deja la base restaurada al costado, sin tocar la que está en uso.

.PARAMETER includeUpdateD365foTools
    Busca en PowerShell Gallery una versión más reciente de d365fo.tools y, si la hay,
    actualiza el módulo (InstallOrUpdateD365foTools.ps1). Sin este modificador se usa
    la versión instalada. Si el módulo no está instalado, se instala igual.

.PARAMETER skipBuildModels
    Omite la fase de compilación de modelos. Solo tiene efecto junto con
    -includeSwitch, porque la compilación cuelga de esa rama.

.PARAMETER skipCheckGitRepoUpdated
    Omite la verificación de que el repositorio de scripts esté actualizado respecto
    del remoto. El pipeline la saltea siempre, porque clona el repositorio en cada
    corrida.

.PARAMETER modelsToBuild
    Lista separada por comas de patrones de búsqueda de módulos a compilar (por
    ejemplo 'Axn*,DevAx*'). Cada entrada se usa como -Name de Get-D365Module. NO tiene
    valor por defecto: si se pidió compilar y llega vacía, el script se detiene antes
    del switch (ver DESCRIPTION).

.EXAMPLE
    .\SQL-ImportBak.ps1 -rutaBak 'J:\MSSQL_BACKUP\AxDB_Backup-CHEFactory01-1-20261016-1014.bak'

    Restaura el .bak como la base AxDB_Backup-CHEFactory01-1-20261016-1014, reconcilia
    sus usuarios y la deja al costado, sin tocar la AxDB activa.

.EXAMPLE
    .\SQL-ImportBak.ps1 -rutaBak 'J:\MSSQL_BACKUP\AxDB_Backup-CHEFactory01-1-20261016-1014.bak' `
                        -includeSwitch `
                        -skipCheckGitRepoUpdated `
                        -modelsToBuild 'Axn*,DevAx*'

    Forma en la que lo invoca el pipeline Migrate-DB-MultiEnv-Bak: restaura, pone la
    base en producción, compila los módulos no binarios que coincidan con los
    patrones, levanta los servicios y corre el DB sync.

.EXAMPLE
    .\SQL-ImportBak.ps1 -rutaBak 'J:\MSSQL_BACKUP\AxDB_Backup-CHEFactory01-1-20261016-1014.bak' -includeSwitch -skipBuildModels

    Restaura y pone la base en producción sin compilar.

.LINK
    SQL-ExportBak.ps1

.LINK
    SqlBakHelpers.ps1

.LINK
    SQL-ImportBacpac.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rutaBak,

    [switch]$includeSwitch,

    [switch]$includeUpdateD365foTools,

    [switch]$skipBuildModels,

    [switch]$skipCheckGitRepoUpdated,

    # CSV en un [string], no [string[]], igual que en SQL-ImportBacpac.ps1: el pipeline
    # pasa las listas así para no pelear con el quoting de arrays en YAML.
    [string]$modelsToBuild
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\PipelineLogging.ps1"
. "$PSScriptRoot\SqlBakHelpers.ps1"

$inicio = Get-Date
$huboError = $false
$pasoActual = 'Validación inicial'

# Usuarios de servicio de D365FO y sus roles: los mismos que crea d365fo.tools al
# importar un .bacpac en Tier 1. Un rol que no existe en la base se saltea.
$usuariosDeServicio = [ordered]@{
    'axdeployuser'                 = @('db_owner')
    'axdbadmin'                    = @('db_owner')
    'axmrruntimeuser'              = @('db_datareader', 'db_datawriter')
    'axretaildatasyncuser'         = @('DataSyncUsersRole')
    'axretailruntimeuser'          = @('UsersRole', 'ReportUsersRole')
    'axdeployextuser'              = @('DeployExtensibilityRole')
    'NT AUTHORITY\NETWORK SERVICE' = @('db_owner')
}

# Sin estos tres el AOS no se conecta a la base: si no quedan mapeados, se corta.
$usuariosImprescindibles = @('axdbadmin', 'axdeployuser', 'NT AUTHORITY\NETWORK SERVICE')

Write-Host "Inicio: $inicio"
Write-Host "Backup: $rutaBak"

try {
    # Validación temprana: fallar acá evita instalar módulos para un archivo que no
    # existe.
    if (-not (Test-Path -Path $rutaBak -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró el archivo .bak indicado: $rutaBak")
    }

    $ImportedDatabaseName = [System.IO.Path]::GetFileNameWithoutExtension($rutaBak)
    Write-Host "Base de datos a crear: $ImportedDatabaseName"

    if (@('AxDB', 'AxDB_original') -contains $ImportedDatabaseName) {
        throw "El .bak se llama '$ImportedDatabaseName', que es el nombre de la base en uso o de la que conserva el switch. Renombrá el archivo: su nombre sin extensión es el nombre de la base que se crea."
    }

    # -------------------------------------------------------------------------
    # Aviso temprano por -modelsToBuild vacío (ver DESCRIPTION). Se vuelve a evaluar
    # después de ajustar la base para abortar antes del switch.
    $seVaACompilar = $includeSwitch -and (-not $skipBuildModels)
    $faltaModelsToBuild = $seVaACompilar -and ((ConvertTo-ListaDesdeCsv -Csv $modelsToBuild).Count -eq 0)

    if ($faltaModelsToBuild) {
        Write-PipelineWarning -Message "Se pidió compilar modelos (-includeSwitch sin -skipBuildModels) pero -modelsToBuild llegó vacío, y este script no tiene lista de modelos por defecto. La restauración del .bak SE VA A EJECUTAR igual, pero el proceso SE VA A DETENER ANTES DEL SWITCH de base. Si no querés esperarla, cancelá esta corrida ahora y volvé a lanzarla con -modelsToBuild cargado, o con -skipBuildModels si de verdad no hay que compilar."
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar repo'
    Start-Phase -Name $pasoActual
    if ($skipCheckGitRepoUpdated) {
        Write-Host 'Se saltea: se recibió -skipCheckGitRepoUpdated.'
        Complete-Phase -Status Skipped
    }
    else {
        # CheckGitRepoUpdated.ps1 hace Set-Location; se restaura el directorio para que
        # las fases siguientes no dependan de dónde quedó parado.
        $directorioPrevio = Get-Location
        try {
            & "$PSScriptRoot\CheckGitRepoUpdated.ps1" -rutaRepositorio $PSScriptRoot
        }
        finally {
            Set-Location -Path $directorioPrevio
        }
        Complete-Phase
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Instalar d365fo.tools'
    Start-Phase -Name $pasoActual
    # Consultar la galería tarda aunque no haya nada que actualizar. Por eso solo se
    # hace cuando se pide; instalar, en cambio, es obligatorio.
    if ($includeUpdateD365foTools) {
        . "$PSScriptRoot\InstallOrUpdateD365foTools.ps1"
    }
    elseif (-not (Get-Module -ListAvailable -Name d365fo.tools)) {
        Write-Host 'El módulo d365fo.tools no está instalado. Se instala la versión más reciente.'
        Install-Module -Name d365fo.tools
    }
    else {
        Write-Host 'Se usa la versión instalada de d365fo.tools: no se recibió -includeUpdateD365foTools.'
    }
    Write-Host 'Importando el módulo d365fo.tools'
    Import-Module -Name d365fo.tools
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar base destino'
    Start-Phase -Name $pasoActual
    if (Test-SqlBaseExiste -NombreBase $ImportedDatabaseName) {
        Complete-Phase -Status Failed
        Write-PipelineError -Message "Ya existe una base de datos '$ImportedDatabaseName' en el servidor, y la restauración solo crea bases nuevas. Suele ser el resto de una restauración anterior que se cortó, así que puede estar incompleta. No es la AxDB en uso. Si se puede descartar, borrala y volvé a ejecutar: ALTER DATABASE [$ImportedDatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$ImportedDatabaseName]; (si quedó en estado RESTORING, alcanza con el DROP DATABASE). NO se tocó nada: ni el .bak, ni la base existente, ni el entorno."

        # 'exit' dentro del try es control de flujo, no una excepción: el catch NO lo
        # intercepta y el finally SÍ corre, así que el resumen de fases sale igual.
        exit 1
    }
    Write-Host "No existe una base '$ImportedDatabaseName' previa: se puede restaurar."
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Validar backup'
    Start-Phase -Name $pasoActual
    $cabecera = Get-SqlBakCabecera -RutaBak $rutaBak
    $servidor = Invoke-SqlConsulta -Sql "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS Mayor, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS Version"

    Write-Host "Base de origen    : $($cabecera.DatabaseName) en $($cabecera.ServerName)"
    Write-Host "Fecha del backup  : $($cabecera.BackupFinishDate)"
    Write-Host ('Tamaño del backup : {0:N2} GB ({1:N2} GB comprimido)' -f ($cabecera.BackupSize / 1GB), ($cabecera.CompressedBackupSize / 1GB))
    Write-Host "SQL Server origen : $($cabecera.SoftwareVersionMajor).$($cabecera.SoftwareVersionMinor).$($cabecera.SoftwareVersionBuild)"
    Write-Host "SQL Server destino: $($servidor[0].Version)"

    # Un backup se restaura en la misma versión mayor o en una más nueva, nunca al revés.
    if ([int]$cabecera.SoftwareVersionMajor -gt [int]$servidor[0].Mayor) {
        throw "El backup se generó en SQL Server $($cabecera.SoftwareVersionMajor).x y esta instancia es $($servidor[0].Version): un backup de una versión más nueva no se puede restaurar."
    }

    $archivosDestino = Get-SqlBakArchivos -RutaBak $rutaBak -NombreBase $ImportedDatabaseName
    Test-SqlEspacioParaRestaurar -Archivos $archivosDestino
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Restaurar base'
    Start-Phase -Name $pasoActual
    Write-Host "Restaurando '$rutaBak' como '$ImportedDatabaseName'"
    Restore-SqlBaseDesdeBak -RutaBak $rutaBak -NombreBase $ImportedDatabaseName -Archivos $archivosDestino
    Write-Host "Verificación OK: la base '$ImportedDatabaseName' quedó ONLINE."
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Reconciliar usuarios'
    Start-Phase -Name $pasoActual
    $idBase = ConvertTo-SqlIdentificador -Nombre $ImportedDatabaseName

    # Después del RESTORE el dueño es el login que restauró (la cuenta del agente).
    Invoke-SqlComando -Sql "ALTER AUTHORIZATION ON DATABASE::$idBase TO [sa]"
    Write-Host 'Dueño de la base: sa.'

    # Huérfano = usuario ligado a un login (SQL o Windows) cuyo SID no existe en este
    # servidor. Se detecta por SID y no por una lista de nombres: así aparecen también
    # los usuarios que alguien creó a mano en el origen.
    $huerfanos = Invoke-SqlConsulta -Base $ImportedDatabaseName -Sql @'
SELECT dp.name AS Nombre,
       dp.type_desc AS Tipo,
       (SELECT TOP (1) sp2.name
          FROM sys.server_principals sp2
         WHERE sp2.name COLLATE DATABASE_DEFAULT = dp.name
           AND ((dp.type = 'S' AND sp2.type = 'S') OR (dp.type IN ('U', 'G') AND sp2.type IN ('U', 'G')))) AS LoginHomonimo
  FROM sys.database_principals dp
  LEFT JOIN sys.server_principals sp ON sp.sid = dp.sid
 WHERE dp.type IN ('S', 'U', 'G')
   AND dp.principal_id > 4
   AND dp.authentication_type IN (1, 3)
   AND sp.sid IS NULL
 ORDER BY dp.name
'@

    $sinResolver = @()
    foreach ($huerfano in $huerfanos) {
        if ($huerfano.LoginHomonimo) {
            $idUsuario = ConvertTo-SqlIdentificador -Nombre $huerfano.Nombre
            $idLogin = ConvertTo-SqlIdentificador -Nombre $huerfano.LoginHomonimo
            Invoke-SqlComando -Base $ImportedDatabaseName -Sql "ALTER USER $idUsuario WITH LOGIN = $idLogin"
            Write-Host "  Remapeado al login de este servidor: $($huerfano.Nombre)"
        }
        else {
            $sinResolver += "$($huerfano.Nombre) ($($huerfano.Tipo))"
        }
    }
    if ($huerfanos.Count -eq 0) {
        Write-Host 'No hay usuarios huérfanos.'
    }

    # Usuarios de servicio que falten: se crean desde su login, y se completan los roles.
    $sqlAsegurarUsuario = @'
DECLARE @sql nvarchar(max);
IF DATABASE_PRINCIPAL_ID(@Usuario) IS NULL
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@Usuario) + N' FROM LOGIN ' + QUOTENAME(@Usuario);
    EXEC (@sql);
    PRINT N'  Usuario creado: ' + @Usuario;
END
'@
    $sqlAsegurarRol = @'
DECLARE @sql nvarchar(max);
IF DATABASE_PRINCIPAL_ID(@Rol) IS NULL
    PRINT N'  El rol ' + @Rol + N' no existe en esta base: se saltea para ' + @Usuario + N'.';
ELSE IF NOT EXISTS (SELECT 1
                      FROM sys.database_role_members
                     WHERE role_principal_id = DATABASE_PRINCIPAL_ID(@Rol)
                       AND member_principal_id = DATABASE_PRINCIPAL_ID(@Usuario))
BEGIN
    SET @sql = N'ALTER ROLE ' + QUOTENAME(@Rol) + N' ADD MEMBER ' + QUOTENAME(@Usuario);
    EXEC (@sql);
    PRINT N'  ' + @Usuario + N' agregado al rol ' + @Rol;
END
'@

    foreach ($usuario in $usuariosDeServicio.Keys) {
        $login = Invoke-SqlConsulta -Sql 'SELECT name FROM sys.server_principals WHERE name = @Usuario' -Parametros @{ Usuario = $usuario }
        if ($login.Count -eq 0) {
            Write-Host "  No existe el login '$usuario' en este servidor: no se crea su usuario."
            continue
        }
        Invoke-SqlComando -Base $ImportedDatabaseName -Sql $sqlAsegurarUsuario -Parametros @{ Usuario = $usuario }
        foreach ($rol in $usuariosDeServicio[$usuario]) {
            Invoke-SqlComando -Base $ImportedDatabaseName -Sql $sqlAsegurarRol -Parametros @{ Usuario = $usuario; Rol = $rol }
        }
    }

    if ($sinResolver.Count -gt 0) {
        Write-PipelineWarning -Message "La base restaurada trae $($sinResolver.Count) usuario(s) sin login equivalente en este servidor, que quedan huérfanos y sin uso: $($sinResolver -join ', '). Suelen ser cuentas Windows locales de la VM de origen. No se borraron."
    }

    $noMapeados = @()
    foreach ($usuario in $usuariosImprescindibles) {
        $mapeado = Invoke-SqlConsulta -Base $ImportedDatabaseName -Sql @'
SELECT u.name
  FROM sys.database_principals u
  JOIN sys.server_principals l ON l.sid = u.sid
 WHERE u.name = @Usuario
'@ -Parametros @{ Usuario = $usuario }
        if ($mapeado.Count -eq 0) { $noMapeados += $usuario }
    }
    if ($noMapeados.Count -gt 0) {
        throw "Después de reconciliar, estos usuarios no quedaron mapeados a un login de este servidor: $($noMapeados -join ', '). Sin ellos el AOS no se conecta a la base. Revisá que los logins existan en la instancia."
    }
    Write-Host "Usuarios imprescindibles mapeados: $($usuariosImprescindibles -join ', ')."
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Ajustar base al entorno'
    Start-Phase -Name $pasoActual

    # Datos del procesador de pagos cifrados con material del entorno de origen: en el
    # destino no se pueden descifrar. Lo mismo hace d365fo.tools en el export Tier 1.
    # Va por SQL dinámico para que el lote compile aunque la tabla no exista.
    Invoke-SqlComando -Base $ImportedDatabaseName -Sql @'
IF COL_LENGTH(N'dbo.RETAILHARDWAREPROFILE', N'SECUREMERCHANTPROPERTIES') IS NOT NULL
BEGIN
    EXEC (N'DISABLE TRIGGER ALL ON dbo.RETAILHARDWAREPROFILE;
            UPDATE dbo.RETAILHARDWAREPROFILE SET SECUREMERCHANTPROPERTIES = NULL WHERE SECUREMERCHANTPROPERTIES IS NOT NULL;
            PRINT N''RETAILHARDWAREPROFILE: '' + CAST(@@ROWCOUNT AS nvarchar(20)) + N'' perfil(es) con SECUREMERCHANTPROPERTIES vaciado.'';
            ENABLE TRIGGER ALL ON dbo.RETAILHARDWAREPROFILE;');
END
'@

    # Un backup entre dos SQL Server no pasa por Azure SQL, así que estos valores tienen
    # que llegar intactos. Se verifican igual porque un AOS con BACKENDDB = SQLAZURE en
    # un Tier 1 no funciona, y es barato comprobarlo.
    $esperados = @{ 'BACKENDDB' = 'SQLSERVER'; 'TEMPTABLEINAXDB' = '0' }
    $configuracion = Invoke-SqlConsulta -Base $ImportedDatabaseName -Sql "SELECT NAME AS Nombre, VALUE AS Valor FROM dbo.SYSGLOBALCONFIGURATION WHERE NAME IN ('BACKENDDB', 'TEMPTABLEINAXDB')"
    foreach ($fila in $configuracion) {
        $esperado = $esperados[[string]$fila.Nombre]
        if ([string]$fila.Valor -ne $esperado) {
            Write-PipelineWarning -Message "SYSGLOBALCONFIGURATION.$($fila.Nombre) llegó con '$($fila.Valor)' y en un Tier 1 tiene que ser '$esperado'. Se corrige."
            Invoke-SqlComando -Base $ImportedDatabaseName -Sql 'UPDATE dbo.SYSGLOBALCONFIGURATION SET VALUE = @Valor WHERE NAME = @Nombre' -Parametros @{ Valor = $esperado; Nombre = [string]$fila.Nombre }
        }
        else {
            Write-Host "SYSGLOBALCONFIGURATION.$($fila.Nombre) = $($fila.Valor)"
        }
    }

    # El backup preserva los catálogos full-text, pero no su población. Repoblarlos es
    # asincrónico y barato; un error acá se informa y no corta la migración.
    Invoke-SqlComando -Base $ImportedDatabaseName -Sql @'
DECLARE @tabla nvarchar(512), @sql nvarchar(max);
DECLARE indices CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(fi.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(fi.object_id))
      FROM sys.fulltext_indexes fi
      JOIN sys.fulltext_catalogs fc ON fc.fulltext_catalog_id = fi.fulltext_catalog_id
     WHERE fc.name = N'COMMERCEFULLTEXTCATALOG';
OPEN indices;
FETCH NEXT FROM indices INTO @tabla;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'ALTER FULLTEXT INDEX ON ' + @tabla + N' ENABLE; ALTER FULLTEXT INDEX ON ' + @tabla + N' START FULL POPULATION;';
        EXEC (@sql);
        PRINT N'Repoblando el índice full-text de ' + @tabla;
    END TRY
    BEGIN CATCH
        PRINT N'No se pudo repoblar el índice full-text de ' + @tabla + N': ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM indices INTO @tabla;
END
CLOSE indices;
DEALLOCATE indices;
'@

    # Opciones que RESTORE puede cambiar (TRUSTWORTHY queda en OFF y Service Broker
    # puede quedar deshabilitado) o que la base trae distintas del origen (la copia de
    # staging se exporta en recovery SIMPLE). No se corrigen a ciegas: se comparan con
    # la AxDB que está en uso en este entorno y se informa cualquier diferencia.
    $opciones = Invoke-SqlConsulta -Sql @'
SELECT name AS Base,
       recovery_model_desc AS RecoveryModel,
       compatibility_level AS CompatibilityLevel,
       is_read_committed_snapshot_on AS ReadCommittedSnapshot,
       snapshot_isolation_state_desc AS SnapshotIsolation,
       is_broker_enabled AS BrokerEnabled,
       is_trustworthy_on AS Trustworthy
  FROM sys.databases
 WHERE name IN (N'AxDB', @Restaurada)
'@ -Parametros @{ Restaurada = $ImportedDatabaseName }

    $actual = $opciones | Where-Object { $_.Base -eq 'AxDB' } | Select-Object -First 1
    $restaurada = $opciones | Where-Object { $_.Base -eq $ImportedDatabaseName } | Select-Object -First 1
    if ($null -eq $actual) {
        Write-Host 'No existe una AxDB en uso en este servidor: no hay contra qué comparar las opciones de base.'
    }
    else {
        $diferencias = @()
        foreach ($opcion in @('RecoveryModel', 'CompatibilityLevel', 'ReadCommittedSnapshot', 'SnapshotIsolation', 'BrokerEnabled', 'Trustworthy')) {
            $valorActual = [string]$actual.$opcion
            $valorRestaurada = [string]$restaurada.$opcion
            Write-Host ('  {0,-22} AxDB actual: {1,-12} restaurada: {2}' -f $opcion, $valorActual, $valorRestaurada)
            if ($valorActual -ne $valorRestaurada) {
                $diferencias += "$opcion (AxDB actual: $valorActual, restaurada: $valorRestaurada)"
            }
        }
        if ($diferencias.Count -gt 0) {
            Write-PipelineWarning -Message "La base restaurada difiere de la AxDB en uso en estas opciones, que no se corrigieron: $($diferencias -join '; '). Si el entorno se comporta distinto después del switch, empezar por acá."
        }
    }
    Complete-Phase

    # -------------------------------------------------------------------------
    # Aborto tardío (ver DESCRIPTION). Se corta acá y no antes porque la restauración es
    # el objetivo primario y NO es destructiva: la base quedó al costado, en paralelo.
    # Todo lo que sigue SÍ toca el entorno en uso, así que sin lista de modelos se
    # frena antes de empezar a romper nada.
    if ($faltaModelsToBuild) {
        Write-PipelineError -Message "Proceso detenido a propósito antes del switch de base: se pidió compilar pero -modelsToBuild llegó vacío y este script no tiene lista de modelos por defecto. LO QUE SÍ SE HIZO: el .bak se restauró, con sus usuarios reconciliados, en la base de datos '$ImportedDatabaseName'. LO QUE NO SE HIZO: detener servicios, switch de base, compilar modelos, iniciar servicios y sincronizar la base. ESTADO DEL ENTORNO: intacto y operativo; la AxDB en uso no se tocó y los servicios siguen arriba. PARA TERMINARLO A MANO hace falta, en este orden: switch de base, compilación de modelos y DB sync. Alternativa: volver a lanzar el pipeline con -modelsToBuild cargado."

        # 'exit' dentro del try es control de flujo, no una excepción: el catch NO lo
        # intercepta (así que no se reporta como fase fallida) pero el finally SÍ se
        # ejecuta, de modo que el resumen de fases y los tiempos salen igual.
        exit 1
    }

    # -------------------------------------------------------------------------
    # ORDEN DELIBERADO DE ACÁ EN ADELANTE, NO REORDENAR (ver DESCRIPTION):
    # Detener servicios -> Switch de base -> Compilar modelos -> Iniciar servicios ->
    # Sincronizar DB. El switch deja la base restaurada en su lugar, la compilación
    # garantiza que no quede metadata sin reflejar en los binarios, y el DB sync
    # concilia la estructura de la base con la versión de los modelos instalados, que
    # es lo que finalmente deja el entorno destino operativo.
    #
    # Todo lo que sigue depende de -includeSwitch (ver DESCRIPTION). Sin ese
    # modificador las cinco fases restantes se registran como salteadas.
    $pasoActual = 'Detener servicios'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Stop-D365Environment

        [int]$AxDB_Original = (Get-D365Database -Name AXDB_ORIGINAL | Measure-Object).Count
        if ($AxDB_Original -gt 0) {
            Write-Host 'Removiendo la base AxDB_original de una migración anterior'
            Remove-D365Database -DatabaseName AxDB_original
        }
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Switch de base'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Write-Host "Activando la base $ImportedDatabaseName como AxDB"
        Switch-D365ActiveDatabase -SourceDatabaseName $ImportedDatabaseName
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Compilar modelos'
    Start-Phase -Name $pasoActual
    if ($includeSwitch -and -not $skipBuildModels) {
        # Cada entrada del CSV es un patrón de búsqueda independiente. Llegar acá con la
        # lista vacía es imposible: el aborto tardío de más arriba ya cortó la corrida.
        $patronesDeModelos = ConvertTo-ListaDesdeCsv -Csv $modelsToBuild
        Write-Host "Patrones de búsqueda recibidos: $($patronesDeModelos -join ', ')"

        # CUIDADO CON Get-D365Module: el valor por defecto de -Name es '*', o sea TODOS
        # los módulos instalados, incluidos los de Microsoft. Compilar eso son horas de
        # trabajo inútil. Por eso -Name siempre se pasa explícito y nunca se deja que
        # aplique el default.
        #
        # -ExcludeBinaryModules descarta los módulos desplegados como binarios, que no
        # tienen código fuente para compilar. En este entorno conviven módulos binarios
        # y módulos con fuentes abiertas (WIP), así que este filtro puede devolver cero
        # resultados de forma perfectamente legítima.
        #
        # -InDependencyOrder devuelve los módulos empezando por los que no referencian
        # a ningún otro, que es el orden en el que hay que compilarlos.
        $modulosACompilar = @()
        foreach ($patron in $patronesDeModelos) {
            $encontrados = @(Get-D365Module -Name $patron -ExcludeBinaryModules -InDependencyOrder)
            Write-Host "  Patrón '$patron': $($encontrados.Count) módulo(s)."

            foreach ($modulo in $encontrados) {
                # Un mismo módulo puede coincidir con más de un patrón; se compila una
                # sola vez. -notcontains es case-insensitive, que es lo correcto para
                # nombres de módulo.
                if ($modulosACompilar.ModuleName -notcontains $modulo.ModuleName) {
                    $modulosACompilar += $modulo
                }
            }
        }

        # Se cuenta ANTES de compilar. Un conjunto vacío no es necesariamente un error
        # (puede ser que todos los módulos del patrón estén desplegados como binarios),
        # pero compilar nada en silencio SÍ lo sería: el log quedaría igual al de una
        # compilación exitosa y nadie se enteraría.
        if ($modulosACompilar.Count -eq 0) {
            Write-PipelineWarning -Message "No se encontró ningún módulo para compilar con los patrones '$($patronesDeModelos -join ', ')'. Puede ser correcto si todos esos módulos están desplegados como binarios, porque -ExcludeBinaryModules los descarta por no tener código fuente. Verificá igual que el patrón sea el correcto para este proyecto. No se compiló nada."
            Complete-Phase -Status Skipped
        }
        else {
            Write-Host "Módulos a compilar ($($modulosACompilar.Count), en orden de dependencias): $($modulosACompilar.ModuleName -join ', ')"

            # Invoke-D365ModuleCompile corre SOLO xppc.exe: código fuente -> assemblies
            # + PDB, que es lo único que hace falta en una migración de base. El anterior
            # 'Invoke-D365ProcessModule -ExecuteCompile' llamaba por dentro a
            # Invoke-D365ModuleFullCompile, que además ejecuta labelc.exe (labels) y
            # reportsc.exe (reportes): trabajo desperdiciado en este contexto.
            #
            # NO AGREGAR -XRefGenerationOnly. El ejemplo 5 de la documentación oficial
            # de Invoke-D365ModuleCompile lo incluye y es tentador "completar" el ejemplo,
            # pero ese modificador hace que el compilador SOLO genere metadata de XRef y
            # NO actualice los assemblies ni los PDB, o sea exactamente lo contrario de
            # lo que se busca acá.
            #
            # El pipe funciona porque -Module se enlaza por nombre de propiedad
            # (ValueFromPipelineByPropertyName) y Get-D365Module emite objetos con la
            # propiedad Module.
            #
            # LIMITACIÓN CONOCIDA, IMPORTANTE: con -ShowOriginalProgress, d365fo.tools
            # NO evalúa el código de salida de xppc.exe. Su helper interno Invoke-Process
            # condiciona ese chequeo a "-not $ShowOriginalProgress", así que en este modo
            # una compilación que falla NO lanza excepción y NO hace fallar el step. Es
            # el precio de ver el progreso en vivo en una fase larga, y era igual con el
            # Invoke-D365ProcessModule anterior. Por eso se imprimen abajo las rutas de
            # los logs de xppc: son el único lugar donde queda constancia del resultado
            # real de cada módulo.
            #
            # Verificar el efecto tampoco sirve: los assemblies ya existen de la
            # compilación anterior, así
            # que su presencia no prueba nada, y comparar LastWriteTime por módulo es
            # frágil (un módulo sin cambios puede no reescribirse).
            # TODO: hacer fallar la fase leyendo el XML que xppc deja en
            # $resultado.XmlLogFile. Es la señal confiable: contiene los diagnósticos
            # con su severidad, así que alcanza con parsearlo y cortar si aparece algún
            # nodo de error. Se deja pendiente para no ampliar el alcance de este cambio.
            $resultadosCompilacion = @($modulosACompilar | Invoke-D365ModuleCompile -ShowOriginalProgress)

            # Se consumen los objetos que devuelve el cmdlet en vez de dejarlos caer al
            # stream de salida del script, y se muestran como texto.
            foreach ($resultado in $resultadosCompilacion) {
                Write-Host "  Log de compilación: $($resultado.LogFile)"
            }
            Complete-Phase
        }
    }
    else {
        if (-not $includeSwitch) {
            Write-Host 'Se saltea: no se recibió -includeSwitch (la compilación cuelga de esa rama).'
        }
        else {
            Write-Host 'Se saltea: se recibió -skipBuildModels.'
        }
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Iniciar servicios'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Start-D365EnvironmentV2 -Aos -Batch
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Sincronizar DB'
    Start-Phase -Name $pasoActual
    if ($includeSwitch) {
        Invoke-D365DbSync
        Complete-Phase
    }
    else {
        Write-Host 'Se saltea: no se recibió -includeSwitch.'
        Complete-Phase -Status Skipped
    }
}
catch {
    # Cierra como fallida la fase que estuviera abierta, para que el "##[endgroup]"
    # salga igual y la fila aparezca en el resumen.
    Complete-Phase -Status Failed
    Write-PipelineError -Message "Falló la fase '$pasoActual': $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $huboError = $true
}
finally {
    Write-PhaseSummary

    $fin = Get-Date
    Write-Host "Inicio: $inicio"
    Write-Host "Final : $fin"
    Write-Host "Tiempo total transcurrido: $($fin - $inicio)" -ForegroundColor Magenta
}

# El exit va después del finally para que el resumen salga una sola vez y siempre, y
# para que el código de salida sea el que decide si el step del pipeline queda en rojo.
if ($huboError) {
    exit 1
}
