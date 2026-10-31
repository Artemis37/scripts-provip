<#
.SYNOPSIS
    Menu to install, uninstall, reload and restore databases for SQL Server running in Docker.

.DESCRIPTION
    Settings live in .env next to this script (created on first run with a random sa password).
    README.md describes each setting.

    Install and Reload always build a brand-new container, so SQL Server starts with fresh system
    databases (master, model, msdb) and the sa password from .env. Your own databases live in a
    folder on this PC that is mounted into the container, and are attached again on every start:

        mssql\databases -> /var/opt/mssql/databases   every .mdf here is attached; drop yours in,
                                                      restored and newly created databases land here too
        mssql\backup    -> /var/opt/mssql/backup      drop .bak here, then "4) Restore"
        mssql\log       -> /var/opt/mssql/log         SQL Server error logs

    Anything kept only in master/msdb (logins other than sa, SQL Agent jobs, server settings)
    starts over with every new container.

    Requires Docker Desktop running Linux containers.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\sqlserver.ps1
#>

$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$EnvFile   = Join-Path $ScriptDir '.env'

# Folders inside the container. The system databases stay in the container's own
# /var/opt/mssql/data, which is thrown away with the container.
$C_DB     = '/var/opt/mssql/databases'
$C_BACKUP = '/var/opt/mssql/backup'
$C_LOG    = '/var/opt/mssql/log'

$script:Config = $null
$script:SqlCmd = $null   # sqlcmd path + flags inside the container, found on first use

# ------------------------------------------------------------------ output helpers

function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok  ([string]$Message) { Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Err ([string]$Message) { Write-Host "  $Message" -ForegroundColor Red }

function Write-SqlOutput($Result) {
    foreach ($line in $Result.Output) { if ($line.Trim()) { Write-Host "    $line" } }
}

function Write-VersionHint($Result) {
    if ($Result.Output -match 'cannot be opened because it is version|incompatible with this server') {
        Write-Warn "These files come from a newer SQL Server than $($Config.Image)."
        Write-Warn 'Set SQL_IMAGE in .env to a newer tag (e.g. 2025-latest), then run option 3.'
    }
}

function Clear-Screen {
    if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch { } }
}

# ------------------------------------------------------------------ .env

function New-SaPassword([int]$Length = 20) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@-_+')
    $all  = -join $sets
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf  = New-Object byte[] 4
    $next = { param([int]$Max) $rng.GetBytes($buf); [int]([BitConverter]::ToUInt32($buf, 0) % [uint32]$Max) }

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) { $chars.Add($set[(& $next $set.Length)]) }   # at least one of each kind
    while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = & $next ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

# SQL Server rule: 8+ characters from at least 3 of: upper case, lower case, digits, symbols.
function Test-SaPassword([string]$Password) {
    if ($Password.Length -lt 8) { return $false }
    $kinds = 0
    if ($Password -cmatch '[A-Z]') { $kinds++ }
    if ($Password -cmatch '[a-z]') { $kinds++ }
    if ($Password -match '\d') { $kinds++ }
    if ($Password -match '[^A-Za-z0-9]') { $kinds++ }
    return $kinds -ge 3
}

function New-EnvFile {
    $password = New-SaPassword
    $text = @"
# See README.md for what each setting does.
SA_PASSWORD=$password
SQL_PORT=1433
CONTAINER_NAME=sqlserver
SQL_IMAGE=mcr.microsoft.com/mssql/server:2022-latest
MSSQL_PID=Developer
MSSQL_DIR=./mssql
"@
    Set-Content -LiteralPath $EnvFile -Value $text -Encoding ASCII
    Write-Ok "Created $EnvFile with a random sa password."
}

function Read-EnvFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) { New-EnvFile }
    $vars = @{}
    foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $value = $line.Substring($eq + 1).Trim()
        if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and $value[0] -in '"', "'") {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $vars[$line.Substring(0, $eq).Trim()] = $value
    }
    $vars
}

function Get-Config {
    $vars = Read-EnvFile
    $get  = { param($Key, $Default) if ($vars[$Key]) { $vars[$Key] } else { $Default } }

    $port = 0
    if (-not [int]::TryParse((& $get 'SQL_PORT' '1433'), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "SQL_PORT in $EnvFile must be a port number."
    }
    $root = & $get 'MSSQL_DIR' './mssql'
    if (-not [System.IO.Path]::IsPathRooted($root)) { $root = Join-Path $ScriptDir $root }
    $root = [System.IO.Path]::GetFullPath($root).TrimEnd('\')

    [pscustomobject]@{
        Password  = [string]$vars['SA_PASSWORD']
        Port      = $port
        Container = & $get 'CONTAINER_NAME' 'sqlserver'
        Image     = & $get 'SQL_IMAGE' 'mcr.microsoft.com/mssql/server:2022-latest'
        Edition   = & $get 'MSSQL_PID' 'Developer'
        RootDir   = $root
        DbDir     = Join-Path $root 'databases'
        BackupDir = Join-Path $root 'backup'
        LogDir    = Join-Path $root 'log'
    }
}

function Initialize-Folders {
    foreach ($dir in $Config.DbDir, $Config.BackupDir, $Config.LogDir) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
}

# C:\...\mssql\databases\Sales\Sales.mdf -> /var/opt/mssql/databases/Sales/Sales.mdf
function ConvertTo-ContainerPath([string]$HostPath, [string]$HostRoot, [string]$ContainerRoot) {
    $ContainerRoot + ($HostPath.Substring($HostRoot.Length) -replace '\\', '/')
}

function ConvertTo-DbPath([string]$HostPath) { ConvertTo-ContainerPath $HostPath $Config.DbDir $C_DB }

# ------------------------------------------------------------------ docker / sql helpers

function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err 'Docker was not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
        return $false
    }
    $os = & docker info --format '{{.OSType}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'Docker is installed but not running. Start Docker Desktop and try again.'
        return $false
    }
    if ("$os".Trim() -ne 'linux') {
        Write-Err 'Docker is using Windows containers. Right-click the Docker tray icon > "Switch to Linux containers".'
        return $false
    }
    return $true
}

function Get-ContainerState {
    $state = & docker inspect --format '{{.State.Status}}' $Config.Container 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$state".Trim()
}

function Get-StatusText {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'Docker not installed' }
    $state = Get-ContainerState
    if ($state) { return $state }
    & docker version --format '{{.Server.Version}}' *> $null
    if ($LASTEXITCODE -ne 0) { return 'Docker not running' }
    return 'not installed'
}

function Test-PortInUse([int]$Port) {
    try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { return $false }
}

function Resolve-SqlCmd {
    $candidates = @(
        @{ Path = '/opt/mssql-tools18/bin/sqlcmd'; Flags = @('-C') },   # 2022+ images; -C trusts the self-signed cert
        @{ Path = '/opt/mssql-tools/bin/sqlcmd';   Flags = @() }        # 2019 images
    )
    foreach ($candidate in $candidates) {
        & docker exec $Config.Container test -x $candidate.Path 2>$null
        if ($LASTEXITCODE -eq 0) {
            $script:SqlCmd = @($candidate.Path) + $candidate.Flags
            return $true
        }
    }
    return $false
}

# Runs T-SQL as sa inside the container. Rows come back as string arrays split on '|'.
function Invoke-Sql {
    param([string]$Query, [int]$LoginTimeout = 15, [switch]$Stream)

    # docker exec -e NAME copies the value from this process, so the password never shows on a command line
    $env:SQLCMDPASSWORD = $Config.Password
    try {
        $output = @(& docker exec -e SQLCMDPASSWORD $Config.Container $script:SqlCmd `
                -S localhost -U sa -l $LoginTimeout -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; $Query" 2>&1 |
            ForEach-Object {
                $line = "$_"
                if ($Stream) { Write-Host "    $line" }
                $line
            })
        $exitCode = $LASTEXITCODE
    } finally {
        Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $output) { if ($line.Trim()) { $rows.Add($line.Split('|')) } }
    [pscustomobject]@{ Ok = ($exitCode -eq 0); Output = $output; Rows = $rows }
}

function Wait-SqlReady([int]$TimeoutSeconds = 180) {
    Write-Host '  Waiting for SQL Server to accept connections' -NoNewline -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $loginFailures = 0
    $last = $null
    $sqlUp = $false
    while ((Get-Date) -lt $deadline) {
        $state = Get-ContainerState
        if ($state -ne 'running') {
            Write-Host ''
            Write-Err "The container is not running (state: $state). Last lines of its log:"
            & docker logs --tail 25 $Config.Container 2>&1 | ForEach-Object { Write-Host "    $_" }
            return $false
        }
        if ($script:SqlCmd -or (Resolve-SqlCmd)) {
            $r = Invoke-Sql 'SELECT 1' -LoginTimeout 5
            if ($r.Ok) {
                # Logins work as soon as master is up, while user databases are still being opened.
                # Wait for "Recovery is complete" in this startup's error log so their state is final.
                $sqlUp = $true
                $recovery = Invoke-Sql "EXEC xp_readerrorlog 0, 1, N'Recovery is complete'"
                if ($recovery.Ok -and $recovery.Rows.Count -gt 0) { Write-Host ' ready.' -ForegroundColor Green; return $true }
                Write-Host '.' -NoNewline -ForegroundColor Cyan
                Start-Sleep -Seconds 2
                continue
            }
            $last = $r.Output
            # "script upgrade mode" also says "Login failed" but is a normal part of startup
            if (($r.Output -match "Login failed for user 'sa'") -and -not ($r.Output -match 'upgrade mode')) {
                $loginFailures++
            } else {
                $loginFailures = 0
            }
            if ($loginFailures -ge 5) {
                Write-Host ''
                Write-Err 'SQL Server rejected SA_PASSWORD from .env.'
                Write-Warn 'If you changed it after the container was created, run option 3 to apply it.'
                return $false
            }
        }
        Write-Host '.' -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 3
    }
    Write-Host ''
    if ($sqlUp) {
        Write-Warn 'SQL Server is up but still opening databases - continuing anyway.'
        return $true
    }
    Write-Err "SQL Server did not become ready within $TimeoutSeconds seconds."
    if ($last) { $last | ForEach-Object { Write-Host "    $_" } }
    Write-Warn "Check the log with: docker logs $($Config.Container)"
    return $false
}

function Connect-Sql {
    if (-not (Test-Docker)) { return $false }
    if ((Get-ContainerState) -ne 'running') {
        Write-Warn 'SQL Server is not running - use option 1 to install or start it.'
        return $false
    }
    return (Wait-SqlReady)
}

function ConvertTo-SqlString([string]$Value) { "N'" + $Value.Replace("'", "''") + "'" }
function ConvertTo-SqlName([string]$Value)   { '[' + $Value.Replace(']', ']]') + ']' }

function Show-Databases {
    $r = Invoke-Sql ("SELECT d.name, d.state_desc, mf.physical_name FROM sys.databases d " +
        "JOIN sys.master_files mf ON mf.database_id = d.database_id AND mf.file_id = 1 " +
        "WHERE d.database_id > 4 ORDER BY d.name")
    if (-not $r.Ok) { return }
    Write-Host ''
    if ($r.Rows.Count -eq 0) { Write-Info 'No user databases yet.'; return }
    Write-Host '  Databases:'
    $list = foreach ($row in $r.Rows) { [pscustomobject]@{ Name = $row[0]; State = $row[1]; 'Data file' = $row[2] } }
    $list | Format-Table -AutoSize | Out-Host
}

function Show-ConnectionInfo {
    Write-Host ''
    Write-Host "  Server    : localhost,$($Config.Port)"
    Write-Host '  Login     : sa'
    Write-Host "  Password  : SA_PASSWORD in $EnvFile"
    Write-Host "  Databases : $($Config.DbDir)  (drop .mdf/.ldf, then option 3)"
    Write-Host "  Backups   : $($Config.BackupDir)  (drop .bak, then option 4)"
    Write-Host "  Conn str  : Server=localhost,$($Config.Port);User Id=sa;Password=<SA_PASSWORD>;TrustServerCertificate=True"
}

# ------------------------------------------------------------------ attaching databases

# Where is a file that an .mdf refers to? At its recorded path when that is inside the databases
# folder, otherwise under the same file name next to the .mdf (files copied from another server).
function Find-DatabaseFile([string]$Recorded, [string]$Folder, $Used) {
    $candidates = @()
    if ($Recorded.StartsWith("$C_DB/")) {
        $candidates += Join-Path $Config.DbDir ($Recorded.Substring($C_DB.Length + 1) -replace '/', '\')
    }
    $leaf = ($Recorded -split '[\\/]')[-1]
    if ($leaf) { $candidates += Join-Path $Folder $leaf }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $path
        if (-not $Used.ContainsKey((ConvertTo-DbPath $file.FullName))) { return $file }
    }
    return $null
}

# Guess the log of an .mdf whose own file list doesn't lead to one:
# Sales_log.ldf, Sales.ldf, or the only .ldf next to the only .mdf.
function Find-LogFile($Mdf, [string]$DbName, $Used) {
    $ldfs = @(Get-ChildItem -LiteralPath $Mdf.DirectoryName -Filter *.ldf -File | Where-Object {
            $_.Extension -eq '.ldf' -and -not $Used.ContainsKey((ConvertTo-DbPath $_.FullName)) })
    foreach ($candidate in "$($Mdf.BaseName)_log", $Mdf.BaseName, "${DbName}_log", $DbName) {
        $ldf = $ldfs | Where-Object { $_.BaseName -eq $candidate } | Select-Object -First 1
        if ($ldf) { return $ldf }
    }
    $mdfCount = @(Get-ChildItem -LiteralPath $Mdf.DirectoryName -Filter *.mdf -File | Where-Object { $_.Extension -eq '.mdf' }).Count
    if ($ldfs.Count -eq 1 -and $mdfCount -eq 1) { return $ldfs[0] }
    return $null
}

# Attaches every .mdf in the databases folder that SQL Server isn't using yet. Files are used in place.
function Sync-DatabaseFolder {
    $mdfs = @(Get-ChildItem -LiteralPath $Config.DbDir -Filter *.mdf -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.mdf' } | Sort-Object FullName)
    if ($mdfs.Count -eq 0) { Write-Info "No .mdf files in $($Config.DbDir) to attach."; return }

    $used = @{}
    foreach ($row in (Invoke-Sql 'SELECT physical_name FROM sys.master_files').Rows) { $used[$row[0]] = $true }
    $names = @{}
    foreach ($row in (Invoke-Sql 'SELECT name FROM sys.databases').Rows) { $names[$row[0]] = $true }

    $attached = 0
    foreach ($mdf in $mdfs) {
        $mdfPath = ConvertTo-DbPath $mdf.FullName
        if ($used.ContainsKey($mdfPath)) { continue }   # already attached

        # The .mdf records its database name and the other files that belong to it.
        $dbName = $mdf.BaseName
        foreach ($row in (Invoke-Sql "DBCC CHECKPRIMARYFILE ($(ConvertTo-SqlString $mdfPath), 2)").Rows) {
            if ($row.Count -eq 2 -and $row[0].Trim() -eq 'Database name' -and $row[1].Trim()) { $dbName = $row[1].Trim() }
        }
        if ($names.ContainsKey($dbName)) {
            Write-Warn "Skipped $($mdf.Name): a database named [$dbName] is already attached."
            continue
        }

        $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        $files.Add($mdf)
        $used[$mdfPath] = $true
        $needLog = $true
        # columns: 0 status (0x40 = log file), 1 file id, 2 logical name, 3 recorded path
        foreach ($row in (Invoke-Sql "DBCC CHECKPRIMARYFILE ($(ConvertTo-SqlString $mdfPath), 3)").Rows) {
            $status = 0
            if ($row.Count -ne 4 -or -not [int]::TryParse($row[0].Trim(), [ref]$status) -or $row[1].Trim() -eq '1') { continue }
            $isLog = ($status -band 0x40) -ne 0
            $file = Find-DatabaseFile $row[3].Trim() $mdf.DirectoryName $used
            if ($file) {
                $files.Add($file)
                $used[(ConvertTo-DbPath $file.FullName)] = $true
                if ($isLog) { $needLog = $false }
            } elseif (-not $isLog) {
                Write-Warn "$($mdf.Name) also needs $(($row[3].Trim() -split '[\\/]')[-1]), which is not in $($mdf.DirectoryName)."
            }
        }
        if ($needLog) {
            $ldf = Find-LogFile $mdf $dbName $used
            if ($ldf) {
                $files.Add($ldf)
                $used[(ConvertTo-DbPath $ldf.FullName)] = $true
                $needLog = $false
            }
        }

        foreach ($file in $files) { if ($file.IsReadOnly) { $file.IsReadOnly = $false } }   # copied files are often read-only
        $on = ($files | ForEach-Object { "(FILENAME = $(ConvertTo-SqlString (ConvertTo-DbPath $_.FullName)))" }) -join ', '

        Write-Info "Attaching $(($files | ForEach-Object { $_.Name }) -join ' + ') as [$dbName]..."
        if ($needLog) {
            $mode = 'FOR ATTACH_REBUILD_LOG'
            Write-Warn "No .ldf found for $($mdf.Name) - SQL Server will try to build a new log file."
        } else {
            $mode = 'FOR ATTACH'
        }
        $r = Invoke-Sql "CREATE DATABASE $(ConvertTo-SqlName $dbName) ON $on $mode"
        if ($r.Ok) {
            Write-Ok "Attached [$dbName]."
            $names[$dbName] = $true
            $attached++
        } else {
            Write-Err "Could not attach $($mdf.Name):"
            Write-SqlOutput $r
            Write-VersionHint $r
        }
    }
    if ($attached -eq 0) { Write-Info 'No new .mdf files to attach.' }
}

# Builds the container from scratch: fresh system databases with the sa password from .env,
# then every .mdf in the databases folder is attached.
function New-SqlContainer {
    if (-not (Test-SaPassword $Config.Password)) {
        Write-Err "SA_PASSWORD in $EnvFile is too weak for SQL Server."
        Write-Warn 'Use 8+ characters with at least 3 of: upper case, lower case, digits, symbols.'
        return
    }

    $hadContainer = [bool](Get-ContainerState)
    if (-not $hadContainer -and (Test-PortInUse $Config.Port)) {
        Write-Err "Port $($Config.Port) is already in use on this PC (a local SQL Server service, or another container?)."
        Write-Warn 'Stop whatever is using it, or set a different SQL_PORT in .env.'
        return
    }

    & docker image inspect $Config.Image *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Downloading $($Config.Image) (large download, first time only)..."
        & docker pull $Config.Image
        if ($LASTEXITCODE -ne 0) { Write-Err 'Image download failed.'; return }
    }

    if ($hadContainer) {
        Write-Info "Removing the old container (your databases stay in $($Config.DbDir))..."
        & docker stop -t 60 $Config.Container | Out-Null   # clean shutdown, so the files can be attached again
        & docker rm $Config.Container | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Could not remove the old container.'; return }
    }

    Initialize-Folders
    Write-Info "Creating container '$($Config.Container)'..."
    $env:MSSQL_SA_PASSWORD = $Config.Password
    try {
        # MSSQL_DATA_DIR/LOG_DIR: databases created in SSMS or by restore land in the mounted folder
        $out = & docker run -d --name $Config.Container --hostname $Config.Container `
            -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e "MSSQL_PID=$($Config.Edition)" `
            -e "MSSQL_DATA_DIR=$C_DB" -e "MSSQL_LOG_DIR=$C_DB" -e "MSSQL_BACKUP_DIR=$C_BACKUP" `
            -p "$($Config.Port):1433" `
            -v "$($Config.DbDir):$C_DB" `
            -v "$($Config.BackupDir):$C_BACKUP" `
            -v "$($Config.LogDir):$C_LOG" `
            --restart unless-stopped $Config.Image 2>&1
    } finally {
        Remove-Item Env:\MSSQL_SA_PASSWORD -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'docker run failed:'
        $out | ForEach-Object { Write-Host "    $_" }
        if ($out -match 'port') { Write-Warn "Port $($Config.Port) looks busy - free it or set a different SQL_PORT in .env." }
        & docker rm -f $Config.Container *> $null
        return
    }

    $script:SqlCmd = $null
    if (-not (Wait-SqlReady)) { return }
    Sync-DatabaseFolder
    Show-Databases
    Show-ConnectionInfo
}

# ------------------------------------------------------------------ menu actions

function Install-SqlServer {
    if (-not (Test-Docker)) { return }
    if ((Get-ContainerState) -eq 'running') {
        Write-Ok "SQL Server is already installed and running (container '$($Config.Container)')."
        Write-Info 'Use option 3 to apply .env changes or attach new .mdf files.'
        Show-ConnectionInfo
        return
    }
    New-SqlContainer
}

function Uninstall-SqlServer {
    if (-not (Test-Docker)) { return }
    if (-not (Get-ContainerState)) {
        Write-Info "There is no container named '$($Config.Container)'."
    } else {
        Write-Warn "This removes container '$($Config.Container)'. Your databases stay in $($Config.DbDir)."
        if ((Read-Host '  Continue? (y/N)') -notmatch '^(y|yes)$') { Write-Info 'Cancelled.'; return }
        Write-Info 'Stopping SQL Server so it closes the databases cleanly...'
        & docker stop -t 60 $Config.Container | Out-Null
        & docker rm $Config.Container | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Could not remove the container.'; return }
        Write-Ok 'Container removed. Option 1 creates it again and attaches your databases.'
    }

    & docker image inspect $Config.Image *> $null
    if ($LASTEXITCODE -eq 0) {
        if ((Read-Host "  Also delete the image $($Config.Image) to free disk space? (y/N)") -match '^(y|yes)$') {
            & docker rmi $Config.Image
        }
    }
}

function Invoke-Reload {
    if (-not (Test-Docker)) { return }
    if (-not (Get-ContainerState)) { Write-Warn 'SQL Server is not installed yet - use option 1.'; return }
    New-SqlContainer
}

function Restore-Backup {
    if (-not (Connect-Sql)) { return }
    Initialize-Folders

    $baks = @(Get-ChildItem -LiteralPath $Config.BackupDir -Filter *.bak -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.bak' } | Sort-Object FullName)
    if ($baks.Count -eq 0) {
        Write-Warn "No .bak files found. Copy one into $($Config.BackupDir) and try again."
        return
    }

    Write-Host ''
    Write-Host "  Backups in $C_BACKUP :"
    for ($i = 0; $i -lt $baks.Count; $i++) {
        $relative = $baks[$i].FullName.Substring($Config.BackupDir.Length + 1)
        Write-Host ('   {0,2}) {1}  ({2:N1} MB)' -f ($i + 1), $relative, ($baks[$i].Length / 1MB))
    }
    $choice = Read-Host '  Pick a backup number (Enter to cancel)'
    $n = 0
    if (-not [int]::TryParse("$choice", [ref]$n) -or $n -lt 1 -or $n -gt $baks.Count) { Write-Info 'Cancelled.'; return }
    $bak  = $baks[$n - 1]
    $disk = ConvertTo-SqlString (ConvertTo-ContainerPath $bak.FullName $Config.BackupDir $C_BACKUP)

    # A .bak can hold several backup sets.
    # HEADERONLY columns used: 2 BackupType (1 full, 2 log, 5 diff), 5 Position, 9 DatabaseName, 18 BackupFinishDate
    $header = Invoke-Sql "RESTORE HEADERONLY FROM DISK = $disk"
    $sets = New-Object System.Collections.Generic.List[object]
    foreach ($row in $header.Rows) { if ($row.Count -gt 18) { $sets.Add($row) } }
    if (-not $header.Ok -or $sets.Count -eq 0) {
        Write-Err 'SQL Server could not read this backup:'
        Write-SqlOutput $header
        return
    }
    $set = $sets[$sets.Count - 1]
    for ($i = $sets.Count - 1; $i -ge 0; $i--) { if ($sets[$i][2] -eq '1') { $set = $sets[$i]; break } }   # newest full backup
    if ($sets.Count -gt 1) {
        Write-Host ''
        Write-Host '  This file holds several backups:'
        foreach ($s in $sets) {
            $type = switch ($s[2]) { '1' { 'Full' } '2' { 'Log' } '5' { 'Differential' } default { "Type $($s[2])" } }
            Write-Host ('   {0,2}) {1,-12} {2,-25} {3}' -f $s[5], $type, $s[9], $s[18])
        }
        $answer = Read-Host "  Which one? [$($set[5])]"
        if ($answer) {
            $picked = $null
            foreach ($s in $sets) { if ($s[5] -eq $answer.Trim()) { $picked = $s } }
            if (-not $picked) { Write-Info 'Cancelled.'; return }
            $set = $picked
        }
    }

    $dbName = Read-Host "  Restore as database name [$($set[9])]"
    if ([string]::IsNullOrWhiteSpace($dbName)) { $dbName = $set[9] }
    $dbName = $dbName.Trim()
    if ($dbName -match '"' -or $dbName -in 'master', 'model', 'msdb', 'tempdb') {
        Write-Err "[$dbName] can't be used as the database name."
        return
    }

    $replace = $false
    $exists = Invoke-Sql "SELECT COUNT(*) FROM sys.databases WHERE name = $(ConvertTo-SqlString $dbName)"
    if ($exists.Ok -and $exists.Rows.Count -gt 0 -and $exists.Rows[0][0] -eq '1') {
        if ((Read-Host "  Database [$dbName] already exists. Overwrite it? (y/N)") -notmatch '^(y|yes)$') { Write-Info 'Cancelled.'; return }
        $replace = $true
    }

    # Move every file in the backup into the databases folder, named after the new database,
    # so it is attached again whenever the container is recreated.
    $fileList = Invoke-Sql "RESTORE FILELISTONLY FROM DISK = $disk WITH FILE = $($set[5])"
    if (-not $fileList.Ok) { Write-Err 'Could not read the file list of this backup:'; Write-SqlOutput $fileList; return }
    $safeName = $dbName -replace '[\\/:*?"<>|]', '_'
    $options = New-Object System.Collections.Generic.List[string]
    $options.Add("FILE = $($set[5])")
    $dataCount = 0
    $logCount = 0
    foreach ($row in $fileList.Rows) {
        if ($row.Count -lt 3) { continue }
        switch ($row[2]) {   # FILELISTONLY columns: 0 LogicalName, 2 Type
            'D' {
                if ($dataCount -eq 0) { $target = "$safeName.mdf" } else { $target = "${safeName}_$dataCount.ndf" }
                $dataCount++
            }
            'L' {
                if ($logCount -eq 0) { $target = "${safeName}_log.ldf" } else { $target = "${safeName}_log$logCount.ldf" }
                $logCount++
            }
            default { $target = "${safeName}_$($row[0] -replace '[\\/:*?"<>|]', '_')" }   # FILESTREAM / full-text folders
        }
        $options.Add("MOVE $(ConvertTo-SqlString $row[0]) TO $(ConvertTo-SqlString "$C_DB/$target")")
    }
    $options.Add('STATS = 10')
    if ($replace) { $options.Add('REPLACE') }

    $sql = "RESTORE DATABASE $(ConvertTo-SqlName $dbName) FROM DISK = $disk WITH $($options -join ', ')"
    if ($replace) {
        # kick out other connections first
        $sql = "IF DATABASEPROPERTYEX($(ConvertTo-SqlString $dbName), 'Status') = 'ONLINE' " +
            "ALTER DATABASE $(ConvertTo-SqlName $dbName) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; $sql"
    }

    Write-Info "Restoring $($bak.Name) as [$dbName]..."
    $r = Invoke-Sql $sql -Stream
    if ($r.Ok) {
        Write-Ok "Restored [$dbName]. Its files are in $($Config.DbDir)."
        Show-Databases
    } else {
        Write-Err 'Restore failed (see the messages above).'
        Write-VersionHint $r
        if ($replace) {
            Invoke-Sql "IF DB_ID($(ConvertTo-SqlString $dbName)) IS NOT NULL ALTER DATABASE $(ConvertTo-SqlName $dbName) SET MULTI_USER" | Out-Null
        }
    }
}

# ------------------------------------------------------------------ menu

function Show-Menu {
    $status = Get-StatusText
    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '   SQL Server in Docker'
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host "   Container : $($Config.Container) ($status)"
    Write-Host "   Server    : localhost,$($Config.Port)"
    Write-Host "   Folder    : $($Config.RootDir)"
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   1) Install SQL Server'
    Write-Host '   2) Uninstall (databases are kept)'
    Write-Host '   3) Reload - fresh container with .env settings,'
    Write-Host '      attach every .mdf in the databases folder'
    Write-Host '   4) Restore a .bak file'
    Write-Host '   Q) Quit'
    Write-Host ''
}

function Start-Menu {
    $actions = @{
        '1' = 'Install-SqlServer'
        '2' = 'Uninstall-SqlServer'
        '3' = 'Invoke-Reload'
        '4' = 'Restore-Backup'
    }
    while ($true) {
        try {
            $script:Config = Get-Config
            Show-Menu
        } catch {
            Write-Err $_.Exception.Message
        }

        $raw = Read-Host '  Choose an option'
        if ($null -eq $raw -or ([Console]::IsInputRedirected -and $raw -eq '')) { return }   # input closed
        $choice = $raw.Trim().ToLower()
        if ($choice -eq 'q') { Write-Host '  Bye.'; return }
        if (-not $actions.ContainsKey($choice)) { Write-Warn 'Choose 1, 2, 3, 4 or Q.'; continue }

        Write-Host ''
        try {
            if ($Config) { & $actions[$choice] }
        } catch {
            Write-Err "Unexpected error: $($_.Exception.Message)"
        }
        Write-Host ''
        Read-Host '  Press Enter to return to the menu' | Out-Null
        Clear-Screen
    }
}

# Dot-sourcing (. .\sqlserver.ps1) only loads the functions; running the script opens the menu.
if ($MyInvocation.InvocationName -ne '.') {
    $previousEncoding = $null
    try { $previousEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try {
        Start-Menu
    } finally {
        if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
    }
}
