<#
.SYNOPSIS
    Exporta la base AxDB de un entorno D365FO Tier 1 a un archivo .bak y publica su
    ruta exacta como variable de salida de Azure DevOps.

.DESCRIPTION
    Genera un backup nativo de SQL Server listo para restaurar en otro entorno Tier 1
    con SQL-ImportBak.ps1. A diferencia del .bacpac, BACKUP y RESTORE copian páginas y
    no reconstruyen el esquema de AxDB (más de 16.000 tablas), que es donde SqlPackage
    pasa la mayor parte del tiempo.

    El trabajo se divide en fases visibles en el log del run y termina con una tabla
    Fase | Duración | Estado.

    LA BASE DE ORIGEN NO SE MODIFICA:
    El .bak no sale de la AxDB viva sino de una copia de staging:
      1. BACKUP ... WITH COPY_ONLY de la base de origen, en caliente.
      2. RESTORE de ese backup como -NewDatabaseName (la copia de staging), que pasa
         a recovery SIMPLE.
      3. Ejecución de -CustomSqlFile contra la copia, si se indicó.
      4. Shrink del log de la copia.
      5. BACKUP de la copia: ese es el .bak que se publica.
      6. Borrado de la copia y del backup intermedio.

    La copia existe aunque no se limpie nada, por el paso 4: RESTORE recrea cada
    archivo con el tamaño que tenía en el origen y, a diferencia del archivo de datos,
    el log siempre se inicializa escribiendo ceros. Un log grande en el origen se
    pagaría en cada restauración de cada destino; achicarlo una vez acá es más barato.

    SALIDA PARA EL PIPELINE:
    Al terminar bien, publica la ruta completa del archivo generado:
      "##vso[task.setvariable variable=ExportedBakFile;isOutput=true]"
    El pipeline la consume en lugar de adivinar cuál es el .bak más reciente de la
    carpeta destino. "isOutput=true" exige que el step de PowerShell tenga un "name:".

    VERIFICACIÓN Y MANEJO DE ERRORES:
    El export se da por exitoso solo si el archivo existe Y su LastWriteTime es
    posterior al inicio de la corrida, de modo que un archivo preexistente con el
    mismo nombre no pueda hacerse pasar por recién generado. Ante cualquier fallo el
    error se registra con "##vso[task.logissue type=error]" y el script termina con
    "exit 1". El borrado de la copia de staging y del directorio temporal nunca
    enmascara un fallo previo: si falla, solo emite una advertencia.

    COPIA DE STAGING DE UNA CORRIDA ANTERIOR:
    Si al empezar ya existe una base llamada -NewDatabaseName, es la copia de staging
    de una corrida que se cortó antes de borrarla: se elimina con una advertencia. El
    nombre no puede ser el de la base de origen, 'AxDB' ni 'AxDB_original'.

    QUIÉN ESCRIBE LOS ARCHIVOS:
    BACKUP y RESTORE los ejecuta la cuenta de servicio de SQL Server, no el usuario que
    corre este script. -BackupDirectory y -TargetPath tienen que ser escribibles para
    esa cuenta.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1 (NO pwsh / PowerShell Core), igual que el resto de los
    scripts de migración. No usa d365fo.tools: todo pasa por System.Data.SqlClient
    (SqlBakHelpers.ps1).

.PARAMETER DatabaseName
    Base de origen a exportar. Por defecto 'AxDB'.

.PARAMETER BackupDirectory
    Directorio para el backup intermedio de la base de origen. Se borra al terminar,
    haya salido bien o mal. Por defecto 'J:\MSSQL_BACKUPTEMP'.

.PARAMETER NewDatabaseName
    Nombre de la copia de staging y prefijo del archivo .bak resultante. Por defecto
    'AxDB_Backup'. Los scripts de limpieza del pipeline solo corren contra bases cuyo
    nombre empieza con 'AxDB_Backup'.

.PARAMETER TargetPath
    Directorio donde queda el .bak generado. Por defecto 'J:\MSSQL_BACKUP'.

.PARAMETER ExtraDescription
    Texto opcional que se agrega al nombre del archivo, después de la marca de tiempo.
    Se le quitan los espacios. Por defecto vacío.

.PARAMETER CustomSqlFile
    Ruta a un archivo .sql que se ejecuta contra la copia de staging antes del backup
    final, en un solo lote. Sirve para vaciar tablas de log y que no viajen en el .bak.
    Si se omite (por defecto, cadena vacía) no se limpia nada. Si se indica una ruta
    inexistente, el script corta con error en vez de exportar sin limpiar.

.PARAMETER LogFileSizeMB
    Tamaño objetivo, en MB, del shrink del log de la copia de staging. Por defecto 1024.

.EXAMPLE
    .\SQL-ExportBak.ps1

    Exporta AxDB con los valores por defecto, sin limpieza: temporal en
    J:\MSSQL_BACKUPTEMP y .bak en J:\MSSQL_BACKUP.

.EXAMPLE
    .\SQL-ExportBak.ps1 -BackupDirectory 'J:\MSSQL_BACKUPTEMP' `
                        -TargetPath 'J:\MSSQL_BACKUP' `
                        -CustomSqlFile 'K:\AgentWork\_temp\bacpac-cleanup.sql'

    Forma en que lo invoca el pipeline Migrate-DB-MultiEnv-Bak: limpia la copia de
    staging con el .sql que genera el pipeline y deja
    AxDB_Backup-<maquina>-<fecha>.bak en J:\MSSQL_BACKUP.

.EXAMPLE
    .\SQL-ExportBak.ps1 -ExtraDescription 'previo a upgrade'

    Genera AxDB_Backup-<maquina>-<fecha>_previoaupgrade.bak.

.LINK
    SQL-ImportBak.ps1

.LINK
    SqlBakHelpers.ps1

.LINK
    SQL-ExportBacpac.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$DatabaseName = 'AxDB',

    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = 'J:\MSSQL_BACKUPTEMP',

    [Parameter(Mandatory = $false)]
    [string]$NewDatabaseName = 'AxDB_Backup',

    [Parameter(Mandatory = $false)]
    [string]$TargetPath = 'J:\MSSQL_BACKUP',

    [Parameter(Mandatory = $false)]
    [string]$ExtraDescription = '',

    [Parameter(Mandatory = $false)]
    [string]$CustomSqlFile = '',

    [Parameter(Mandatory = $false)]
    [int]$LogFileSizeMB = 1024
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\PipelineLogging.ps1"
. "$PSScriptRoot\SqlBakHelpers.ps1"

# Marca de inicio: además de medir, es la referencia contra la que se valida que el
# .bak sea realmente de esta corrida y no de una anterior.
$inicio = Get-Date
$huboError = $false
$pasoActual = 'Validación inicial'
$BakFile = $null
$copiaCreada = $false

Write-Host "Inicio: $inicio"

try {
    # Validación temprana: el nombre de la copia de staging se borra al terminar, así
    # que nunca puede coincidir con una base que haya que conservar.
    if (@($DatabaseName, 'AxDB', 'AxDB_original') -contains $NewDatabaseName) {
        throw "-NewDatabaseName '$NewDatabaseName' no puede ser la base de origen, 'AxDB' ni 'AxDB_original': la copia de staging se borra al terminar."
    }
    if (-not [string]::IsNullOrWhiteSpace($CustomSqlFile) -and -not (Test-Path -Path $CustomSqlFile -PathType Leaf)) {
        throw "No se encontró el archivo de SQL personalizado: $CustomSqlFile"
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Preparar directorios'
    Start-Phase -Name $pasoActual
    foreach ($ruta in @($TargetPath, $BackupDirectory)) {
        if (-not (Test-Path $ruta)) {
            Write-Host "Creando directorio: $ruta"
            New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        }
    }

    # Nombre del archivo: copia + máquina + marca de tiempo, para que dos corridas nunca
    # se pisen y el origen de cada .bak sea evidente desde el nombre. SQL-ImportBak.ps1
    # usa ese mismo nombre, sin extensión, como nombre de la base que restaura.
    $nombreArchivo = "$NewDatabaseName-$env:computername-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    if (-not [string]::IsNullOrWhiteSpace($ExtraDescription)) {
        $nombreArchivo += "_$($ExtraDescription.Replace(' ', ''))"
    }
    $nombreArchivo += '.bak'
    $BakFile = Join-Path $TargetPath $nombreArchivo
    $bakIntermedio = Join-Path $BackupDirectory "$NewDatabaseName-staging.bak"

    Write-Host "Base de origen                : $DatabaseName"
    Write-Host "Copia de staging              : $NewDatabaseName"
    Write-Host "Backup intermedio             : $bakIntermedio"
    Write-Host "Archivo BAK                   : $BakFile"
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Respaldar base de origen'
    Start-Phase -Name $pasoActual
    if (-not (Test-SqlBaseExiste -NombreBase $DatabaseName)) {
        throw "No existe la base de origen '$DatabaseName' en la instancia local."
    }
    Backup-SqlBase -NombreBase $DatabaseName -RutaBak $bakIntermedio
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Restaurar copia de staging'
    Start-Phase -Name $pasoActual
    if (Test-SqlBaseExiste -NombreBase $NewDatabaseName) {
        Write-PipelineWarning -Message "Ya existía la base '$NewDatabaseName': es la copia de staging de una corrida anterior que no llegó a borrarla. Se elimina y se vuelve a crear."
        Remove-SqlBase -NombreBase $NewDatabaseName
    }

    # La copia se ubica junto a los archivos de la base de origen, que es donde la VM
    # tiene el espacio para AxDB.
    $archivosCopia = Get-SqlBakArchivos -RutaBak $bakIntermedio -NombreBase $NewDatabaseName -BaseReferencia $DatabaseName
    Test-SqlEspacioParaRestaurar -Archivos $archivosCopia

    # Se marca antes del RESTORE: si se corta a mitad de camino, la base queda creada
    # e inconsistente, y el finally tiene que borrarla igual.
    $copiaCreada = $true
    Restore-SqlBaseDesdeBak -RutaBak $bakIntermedio -NombreBase $NewDatabaseName -Archivos $archivosCopia

    # La copia hereda el recovery model del origen. En SIMPLE, lo que escriba la
    # limpieza se libera del log en cada CHECKPOINT; en FULL quedaría retenido hasta un
    # backup de log que nunca se hace, y el shrink no podría achicarlo.
    $idCopia = ConvertTo-SqlIdentificador -Nombre $NewDatabaseName
    Invoke-SqlComando -Sql "ALTER DATABASE $idCopia SET RECOVERY SIMPLE WITH NO_WAIT"

    # El backup intermedio ya no hace falta: se libera el espacio antes del backup final.
    Remove-Item -LiteralPath $bakIntermedio -Force
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Limpiar copia de staging'
    Start-Phase -Name $pasoActual
    if ([string]::IsNullOrWhiteSpace($CustomSqlFile)) {
        Write-Host 'Se saltea: no se recibió -CustomSqlFile. Se exporta la base completa.'
        Complete-Phase -Status Skipped
    }
    else {
        Write-Host "SQL de limpieza: $CustomSqlFile"
        # Un solo lote, igual que Invoke-D365SqlScript: el .sql que genera el pipeline
        # está escrito para eso (sin GO). Sus PRINT llegan al log por SqlBakHelpers.
        $sqlLimpieza = Get-Content -LiteralPath $CustomSqlFile -Raw -Encoding UTF8
        Invoke-SqlComando -Sql $sqlLimpieza -Base $NewDatabaseName
        Complete-Phase
    }

    # -------------------------------------------------------------------------
    $pasoActual = 'Achicar log de la copia'
    Start-Phase -Name $pasoActual
    $logs =Invoke-SqlConsulta -Sql 'SELECT name FROM sys.database_files WHERE type = 1' -Base $NewDatabaseName
    foreach ($log in $logs) {
        Write-Host "Achicando el log '$($log.name)' a $LogFileSizeMB MB"
        Invoke-SqlComando -Sql "CHECKPOINT; DBCC SHRINKFILE ($(ConvertTo-SqlLiteral -Texto $log.name), $LogFileSizeMB) WITH NO_INFOMSGS;" -Base $NewDatabaseName
    }

    $tamanos = Invoke-SqlConsulta -Sql 'SELECT name, type_desc, CAST(size AS bigint) * 8 / 1024 AS MB FROM sys.database_files ORDER BY type, file_id' -Base $NewDatabaseName
    foreach ($t in $tamanos) {
        Write-Host ('  {0,-30} {1,-5} {2,10:N0} MB' -f $t.name, $t.type_desc, $t.MB)
    }
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Generar .bak'
    Start-Phase -Name $pasoActual
    Backup-SqlBase -NombreBase $NewDatabaseName -RutaBak $BakFile
    Complete-Phase

    # -------------------------------------------------------------------------
    $pasoActual = 'Verificar archivo'
    Start-Phase -Name $pasoActual
    if (-not (Test-Path -Path $BakFile -PathType Leaf)) {
        throw "No se generó el archivo $BakFile."
    }

    $infoArchivo = Get-Item $BakFile

    # No alcanza con que el archivo exista: tiene que haberse escrito DESPUÉS del inicio
    # de esta corrida. Si no, es el sobrante de una ejecución anterior y darlo por bueno
    # implicaría migrar una base vieja a todos los entornos mostrando verde.
    if ($infoArchivo.LastWriteTime -le $inicio) {
        throw "El archivo $BakFile es anterior al inicio de esta corrida (LastWriteTime $($infoArchivo.LastWriteTime), inicio $inicio); no corresponde a esta ejecución."
    }

    Write-Host "Archivo generado correctamente: $BakFile" -ForegroundColor Green
    Write-Host ('Tamaño del archivo: {0:N2} GB' -f ($infoArchivo.Length / 1GB))
    Write-Host "Última escritura  : $($infoArchivo.LastWriteTime)"

    Write-Host "##vso[task.setvariable variable=ExportedBakFile;isOutput=true]$BakFile"
    Complete-Phase
}
catch {
    Complete-Phase -Status Failed
    Write-PipelineError -Message "Falló la fase '$pasoActual' del export: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $huboError = $true
}
finally {
    # La limpieza corre siempre, pero envuelta en su propio try/catch: un fallo
    # borrando la copia o archivos no debe pisar ni ocultar el error real de arriba, ni
    # cambiar el código de salida del script.
    if ($copiaCreada) {
        try {
            Write-Host "Eliminando la copia de staging $NewDatabaseName"
            Remove-SqlBase -NombreBase $NewDatabaseName
        }
        catch {
            Write-PipelineWarning -Message "No se pudo eliminar la copia de staging '$NewDatabaseName': $($_.Exception.Message). Se borrará al comienzo de la próxima corrida."
        }
    }

    if (Test-Path $BackupDirectory) {
        try {
            Write-Host "Limpiando el directorio temporal $BackupDirectory"
            Remove-Item -Path $BackupDirectory -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-PipelineWarning -Message "No se pudo limpiar el directorio temporal '$BackupDirectory': $($_.Exception.Message)"
        }
    }

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
