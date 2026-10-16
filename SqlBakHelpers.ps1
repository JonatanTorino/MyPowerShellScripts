<#
.SYNOPSIS
    Helper de acceso a SQL Server para la migración de AxDB por .bak. Lo consumen
    SQL-ExportBak.ps1 y SQL-ImportBak.ps1 con dot-sourcing, no como módulo.

.DESCRIPTION
    Provee las funciones que esos dos scripts comparten: ejecutar T-SQL contra la
    instancia local, generar un backup, leer la cabecera y la lista de archivos de un
    .bak, calcular a dónde restaurar cada archivo, restaurar y borrar una base.

    SIN DEPENDENCIAS DE MÓDULOS:
    Todo pasa por System.Data.SqlClient, que viene con .NET Framework. No hace falta
    el módulo SqlServer ni d365fo.tools para ejecutar estas funciones.

    TIMEOUT:
    Cada comando corre con CommandTimeout = 0 (sin límite). El valor por defecto de
    SqlCommand es de 30 segundos, y un BACKUP o un RESTORE de AxDB tarda minutos.

    MENSAJES DEL SERVIDOR:
    Los mensajes informativos (PRINT, el progreso de STATS de BACKUP y RESTORE, la
    salida de DBCC) se reenvían a Write-Host a medida que el cliente los recibe. Los
    errores de severidad 11 o mayor siguen lanzando SqlException: no se convierten en
    mensajes, así que un fallo nunca pasa en silencio.

    IDENTIFICADORES:
    Los nombres de base y de archivo se interpolan en DDL dinámico, porque ni
    ALTER DATABASE ni las cláusulas MOVE aceptan parámetros. Se escapan siempre con
    ConvertTo-SqlIdentificador y ConvertTo-SqlLiteral.

    REQUISITO DE PLATAFORMA:
    Windows PowerShell 5.1, igual que los scripts que lo consumen.

.EXAMPLE
    . "$PSScriptRoot\SqlBakHelpers.ps1"

    Invoke-SqlComando -Sql 'CHECKPOINT' -Base 'AxDB_Backup'

    Ejecuta CHECKPOINT en la base AxDB_Backup de la instancia local.

.LINK
    SQL-ExportBak.ps1

.LINK
    SQL-ImportBak.ps1
#>

function ConvertTo-SqlIdentificador {
    <#
    .SYNOPSIS
        Devuelve el nombre entre corchetes y con los ']' escapados, listo para DDL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Nombre
    )

    return '[' + $Nombre.Replace(']', ']]') + ']'
}

function ConvertTo-SqlLiteral {
    <#
    .SYNOPSIS
        Devuelve el texto como literal Unicode de T-SQL (N'...') con las comillas escapadas.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Texto
    )

    return "N'" + $Texto.Replace("'", "''") + "'"
}

function New-SqlConexion {
    <#
    .SYNOPSIS
        Abre una conexión a la instancia local con autenticación integrada.

    .DESCRIPTION
        La conexión reenvía a Write-Host cada mensaje informativo del servidor. Se
        desactiva el pooling para que cerrar la conexión la libere de verdad: un DROP
        DATABASE o un SINGLE_USER posterior no deben chocar con una conexión que quedó
        viva en el pool.

    .PARAMETER Base
        Base inicial de la conexión. Por defecto 'master'.

    .PARAMETER Servidor
        Instancia de SQL Server. Por defecto 'localhost'.
    #>
    [CmdletBinding()]
    [OutputType([System.Data.SqlClient.SqlConnection])]
    param (
        [string]$Base = 'master',

        [string]$Servidor = 'localhost'
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Servidor
    $builder['Initial Catalog'] = $Base
    $builder['Integrated Security'] = $true
    $builder['Pooling'] = $false
    $builder['Application Name'] = 'MigracionAxDB-Bak'

    $conexion = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $conexion.add_InfoMessage({
            param ($emisor, $evento)
            foreach ($mensaje in $evento.Errors) {
                Write-Host $mensaje.Message
            }
        })
    $conexion.Open()
    return $conexion
}

function New-SqlComandoConParametros {
    # Uso interno: arma el SqlCommand con timeout ilimitado y los parámetros dados.
    param (
        [System.Data.SqlClient.SqlConnection]$Conexion,
        [string]$Sql,
        [hashtable]$Parametros
    )

    $comando = $Conexion.CreateCommand()
    $comando.CommandText = $Sql
    $comando.CommandTimeout = 0
    if ($Parametros) {
        foreach ($clave in $Parametros.Keys) {
            $valor = $Parametros[$clave]
            if ($null -eq $valor) { $valor = [System.DBNull]::Value }
            $null = $comando.Parameters.AddWithValue("@$clave", $valor)
        }
    }
    return $comando
}

function Invoke-SqlComando {
    <#
    .SYNOPSIS
        Ejecuta un lote de T-SQL que no devuelve filas.

    .DESCRIPTION
        El lote se manda entero en un solo SqlCommand: GO no existe acá, porque lo
        interpreta el cliente sqlcmd, no el servidor.

    .PARAMETER Sql
        Texto del lote.

    .PARAMETER Base
        Base contra la que se ejecuta. Por defecto 'master'.

    .PARAMETER Parametros
        Hashtable de parámetros: la clave 'Ruta' se enlaza a '@Ruta' en el lote.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$Base = 'master',

        [hashtable]$Parametros
    )

    $conexion = New-SqlConexion -Base $Base
    try {
        $comando = New-SqlComandoConParametros -Conexion $conexion -Sql $Sql -Parametros $Parametros
        $null = $comando.ExecuteNonQuery()
    }
    finally {
        $conexion.Dispose()
    }
}

function Invoke-SqlConsulta {
    <#
    .SYNOPSIS
        Ejecuta una consulta y devuelve sus filas como objetos.

    .DESCRIPTION
        Devuelve un arreglo de PSCustomObject con una propiedad por columna del primer
        result set. Los valores NULL llegan como $null. Siempre devuelve un arreglo,
        aunque tenga cero o una fila.

    .PARAMETER Sql
        Texto de la consulta.

    .PARAMETER Base
        Base contra la que se ejecuta. Por defecto 'master'.

    .PARAMETER Parametros
        Hashtable de parámetros, igual que en Invoke-SqlComando.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$Base = 'master',

        [hashtable]$Parametros
    )

    $conexion = New-SqlConexion -Base $Base
    try {
        $comando = New-SqlComandoConParametros -Conexion $conexion -Sql $Sql -Parametros $Parametros
        $lector = $comando.ExecuteReader()
        $filas = New-Object System.Collections.Generic.List[psobject]
        try {
            while ($lector.Read()) {
                $fila = [ordered]@{}
                for ($i = 0; $i -lt $lector.FieldCount; $i++) {
                    $valor = $lector.GetValue($i)
                    if ($valor -is [System.DBNull]) { $valor = $null }
                    $fila[$lector.GetName($i)] = $valor
                }
                $filas.Add([pscustomobject]$fila)
            }
        }
        finally {
            $lector.Dispose()
        }
        return , $filas.ToArray()
    }
    finally {
        $conexion.Dispose()
    }
}

function Test-SqlBaseExiste {
    <#
    .SYNOPSIS
        Indica si existe una base con ese nombre en la instancia local.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NombreBase
    )

    $filas = Invoke-SqlConsulta -Sql 'SELECT name FROM sys.databases WHERE name = @Nombre' -Parametros @{ Nombre = $NombreBase }
    return ($filas.Count -gt 0)
}

function Remove-SqlBase {
    <#
    .SYNOPSIS
        Borra una base de la instancia local, cortando las conexiones abiertas.

    .DESCRIPTION
        Rechaza 'AxDB' y 'AxDB_original' sin importar mayúsculas: estas funciones
        borran copias de trabajo, nunca la base en uso ni la que conserva el switch.
        Si la base no existe, no hace nada.

        Una base que quedó en estado RESTORING (un RESTORE que se cortó) no admite
        ALTER DATABASE ... SET SINGLE_USER, y tampoco tiene conexiones que cortar: se
        borra con DROP DATABASE directo.

    .PARAMETER NombreBase
        Base a borrar.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NombreBase
    )

    if (@('AxDB', 'AxDB_original') -contains $NombreBase) {
        throw "Remove-SqlBase se niega a borrar '$NombreBase': solo borra copias de trabajo."
    }

    $estado = Invoke-SqlConsulta -Sql 'SELECT state_desc FROM sys.databases WHERE name = @Nombre' -Parametros @{ Nombre = $NombreBase }
    if ($estado.Count -eq 0) { return }

    $id = ConvertTo-SqlIdentificador -Nombre $NombreBase
    if ($estado[0].state_desc -eq 'RESTORING') {
        Invoke-SqlComando -Sql "DROP DATABASE $id;"
    }
    else {
        Invoke-SqlComando -Sql "ALTER DATABASE $id SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $id;"
    }
    Write-Host "Base '$NombreBase' eliminada."
}

function Backup-SqlBase {
    <#
    .SYNOPSIS
        Genera un backup completo, comprimido y con checksum de una base local.

    .DESCRIPTION
        Usa COPY_ONLY para no alterar la cadena de backups de la base: se puede
        ejecutar en caliente sobre la AxDB en uso. INIT sobrescribe el contenido del
        archivo si ya existía, de modo que el .bak contiene un único backup set.

    .PARAMETER NombreBase
        Base a respaldar.

    .PARAMETER RutaBak
        Ruta completa del .bak a generar. La carpeta tiene que existir y la cuenta de
        servicio de SQL Server tiene que poder escribir en ella.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NombreBase,

        [Parameter(Mandatory = $true)]
        [string]$RutaBak
    )

    $id = ConvertTo-SqlIdentificador -Nombre $NombreBase
    Invoke-SqlComando -Sql "BACKUP DATABASE $id TO DISK = @Ruta WITH COPY_ONLY, COMPRESSION, CHECKSUM, INIT, SKIP, STATS = 10" -Parametros @{ Ruta = $RutaBak }
}

function Get-SqlBakCabecera {
    <#
    .SYNOPSIS
        Devuelve la cabecera del único backup set de un .bak (RESTORE HEADERONLY).

    .DESCRIPTION
        Falla si el archivo contiene más de un backup set o si no es un backup
        completo de base (BackupType 1): restaurar "el primero de varios" es justo la
        clase de elección silenciosa que estos scripts evitan.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RutaBak
    )

    $sets = Invoke-SqlConsulta -Sql 'RESTORE HEADERONLY FROM DISK = @Ruta' -Parametros @{ Ruta = $RutaBak }
    if ($sets.Count -ne 1) {
        throw "El archivo '$RutaBak' contiene $($sets.Count) backup sets y se esperaba exactamente uno."
    }
    if ($sets[0].BackupType -ne 1) {
        throw "El backup de '$RutaBak' no es un backup completo de base (BackupType $($sets[0].BackupType))."
    }
    return $sets[0]
}

function Get-SqlBakArchivos {
    <#
    .SYNOPSIS
        Lista los archivos de un .bak y calcula a dónde restaurar cada uno.

    .DESCRIPTION
        Lee RESTORE FILELISTONLY: los nombres lógicos salen siempre de ahí y nunca se
        suponen, porque después de varios switches de base no se llaman AXDB/AXDB_log.

        La carpeta de destino de cada archivo es la misma donde viven hoy los archivos
        del mismo tipo de la base de referencia (por defecto AxDB), que es donde la VM
        tiene el espacio para la base. Si esa base no existe se usa la carpeta por
        defecto de la instancia.

        El nombre físico de destino sale de la base nueva: '<base>.mdf' para el primer
        archivo de datos, '<base>_<FileId>.ndf' para los demás y '<base>_log.ldf' para
        el log (con sufijo de FileId si hubiera más de uno). Así dos restauraciones con
        nombres de base distintos nunca comparten archivos.

    .PARAMETER RutaBak
        Ruta completa al .bak.

    .PARAMETER NombreBase
        Nombre de la base que se va a crear con la restauración.

    .PARAMETER BaseReferencia
        Base cuya ubicación de archivos se toma como destino. Por defecto 'AxDB'.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RutaBak,

        [Parameter(Mandatory = $true)]
        [string]$NombreBase,

        [string]$BaseReferencia = 'AxDB'
    )

    $archivos = Invoke-SqlConsulta -Sql 'RESTORE FILELISTONLY FROM DISK = @Ruta' -Parametros @{ Ruta = $RutaBak }
    if ($archivos.Count -eq 0) {
        throw "RESTORE FILELISTONLY no devolvió archivos para '$RutaBak'."
    }

    $ubicaciones = Invoke-SqlConsulta -Sql @'
SELECT TOP (1)
       (SELECT TOP (1) physical_name FROM sys.master_files WHERE database_id = DB_ID(@Referencia) AND type = 0 ORDER BY file_id) AS DatosReferencia,
       (SELECT TOP (1) physical_name FROM sys.master_files WHERE database_id = DB_ID(@Referencia) AND type = 1 ORDER BY file_id) AS LogReferencia,
       CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS DatosDefecto,
       CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS LogDefecto
'@ -Parametros @{ Referencia = $BaseReferencia }

    $carpetaDatos = if ($ubicaciones[0].DatosReferencia) { [System.IO.Path]::GetDirectoryName([string]$ubicaciones[0].DatosReferencia) } else { $ubicaciones[0].DatosDefecto }
    $carpetaLog = if ($ubicaciones[0].LogReferencia) { [System.IO.Path]::GetDirectoryName([string]$ubicaciones[0].LogReferencia) } else { $ubicaciones[0].LogDefecto }

    if ([string]::IsNullOrWhiteSpace($carpetaDatos) -or [string]::IsNullOrWhiteSpace($carpetaLog)) {
        throw "No se pudo determinar la carpeta de datos o de log para restaurar (base de referencia '$BaseReferencia')."
    }

    $cantidadLogs = @($archivos | Where-Object { $_.Type -eq 'L' }).Count
    $primerDatos = $true
    $resultado = foreach ($archivo in $archivos) {
        $extension = [System.IO.Path]::GetExtension([string]$archivo.PhysicalName)
        switch ([string]$archivo.Type) {
            'D' {
                $carpeta = $carpetaDatos
                if ($primerDatos) {
                    $nombre = "$NombreBase$extension"
                    $primerDatos = $false
                }
                else {
                    $nombre = "${NombreBase}_$($archivo.FileId)$extension"
                }
            }
            'L' {
                $carpeta = $carpetaLog
                $nombre = if ($cantidadLogs -gt 1) { "${NombreBase}_log$($archivo.FileId)$extension" } else { "${NombreBase}_log$extension" }
            }
            default {
                # Full-text (F) o FILESTREAM (S): AxDB no los usa como archivos propios;
                # si aparecieran, se ubican junto a los datos para no perderlos.
                $carpeta = $carpetaDatos
                $nombre = "${NombreBase}_$($archivo.FileId)$extension"
            }
        }

        [pscustomobject]@{
            NombreLogico = [string]$archivo.LogicalName
            Tipo         = [string]$archivo.Type
            Bytes        = [long]$archivo.Size
            RutaDestino  = [System.IO.Path]::Combine($carpeta, $nombre)
        }
    }

    return , @($resultado)
}

function Test-SqlEspacioParaRestaurar {
    <#
    .SYNOPSIS
        Verifica que cada volumen de destino tenga lugar para los archivos a restaurar.

    .DESCRIPTION
        RESTORE recrea cada archivo con el tamaño que tenía en el origen, aunque esté
        casi vacío. Se suma ese tamaño por volumen y se compara con el espacio libre,
        con un margen del 5%. Falla antes de empezar a restaurar, en lugar de que el
        RESTORE se corte a mitad de camino con el disco lleno.

    .PARAMETER Archivos
        Salida de Get-SqlBakArchivos.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Archivos
    )

    # Rutas como texto, sin el proveedor de PowerShell: no exige que la unidad exista
    # en la sesión para calcular la raíz.
    $porVolumen = $Archivos | Group-Object -Property { [System.IO.Path]::GetPathRoot($_.RutaDestino) }
    foreach ($grupo in $porVolumen) {
        $necesario = ($grupo.Group | Measure-Object -Property Bytes -Sum).Sum
        $libre = (New-Object System.IO.DriveInfo $grupo.Name).AvailableFreeSpace
        Write-Host ('Volumen {0}: se necesitan {1:N2} GB, hay {2:N2} GB libres.' -f $grupo.Name, ($necesario / 1GB), ($libre / 1GB))
        if ($necesario * 1.05 -gt $libre) {
            throw ("No hay espacio en {0} para restaurar: se necesitan {1:N2} GB (más 5% de margen) y hay {2:N2} GB libres." -f $grupo.Name, ($necesario / 1GB), ($libre / 1GB))
        }
    }
}

function Restore-SqlBaseDesdeBak {
    <#
    .SYNOPSIS
        Restaura un .bak como una base NUEVA, reubicando sus archivos.

    .DESCRIPTION
        Nunca usa WITH REPLACE: si la base ya existe, el RESTORE falla y no pisa nada.
        WITH CHECKSUM valida las páginas contra los checksums que dejó el backup. Al
        terminar verifica que la base haya quedado ONLINE.

    .PARAMETER RutaBak
        Ruta completa al .bak. La cuenta de servicio de SQL Server tiene que poder
        leerla.

    .PARAMETER NombreBase
        Nombre de la base a crear.

    .PARAMETER Archivos
        Salida de Get-SqlBakArchivos para ese .bak y esa base.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RutaBak,

        [Parameter(Mandatory = $true)]
        [string]$NombreBase,

        [Parameter(Mandatory = $true)]
        [object[]]$Archivos
    )

    $movimientos = ($Archivos | ForEach-Object {
            'MOVE ' + (ConvertTo-SqlLiteral -Texto $_.NombreLogico) + ' TO ' + (ConvertTo-SqlLiteral -Texto $_.RutaDestino)
        }) -join ', '

    foreach ($archivo in $Archivos) {
        Write-Host "  $($archivo.NombreLogico) ($($archivo.Tipo)) -> $($archivo.RutaDestino)"
    }

    $id = ConvertTo-SqlIdentificador -Nombre $NombreBase
    Invoke-SqlComando -Sql "RESTORE DATABASE $id FROM DISK = @Ruta WITH $movimientos, CHECKSUM, STATS = 10" -Parametros @{ Ruta = $RutaBak }

    $estado = Invoke-SqlConsulta -Sql 'SELECT state_desc FROM sys.databases WHERE name = @Nombre' -Parametros @{ Nombre = $NombreBase }
    if ($estado.Count -eq 0 -or $estado[0].state_desc -ne 'ONLINE') {
        $descripcion = if ($estado.Count -eq 0) { 'inexistente' } else { $estado[0].state_desc }
        throw "La base '$NombreBase' no quedó ONLINE después del RESTORE (estado: $descripcion)."
    }
}
