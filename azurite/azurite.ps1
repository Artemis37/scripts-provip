<#
.SYNOPSIS
    Menu to install and uninstall Azurite, the Azure Storage emulator, and Durable Functions Monitor
    with Docker Compose.

.DESCRIPTION
    compose.yaml next to this script defines two containers:

        azurite   Blob, Queue and Table storage on the standard emulator ports, so apps connect with
                  UseDevelopmentStorage=true. Its data lives in the data folder next to this script
                  and is kept when Azurite is uninstalled:  azurite\data -> /data
        dfmon     Durable Functions Monitor on http://localhost:7072, showing the Durable Functions
                  task hubs of the storage account set in .env: Azurite by default, or a real account.

    .env next to this script is created from .env.example on first run and holds that connection
    string. To change images or ports, edit compose.yaml, and the ports below to match.

    Requires Docker Desktop running Linux containers.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\azurite\azurite.ps1
#>

param(
    # Set by dev.ps1: Q goes back to the dev menu instead of quitting
    [switch]$FromDevMenu
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\helper\common.ps1')

$ComposeFile = Join-Path $PSScriptRoot 'compose.yaml'
$EnvFile     = Join-Path $PSScriptRoot '.env'
$DataDir     = Join-Path $PSScriptRoot 'data'

# Container names and published ports, as set in compose.yaml
$Container   = 'azurite'
$Monitor     = 'dfmon'
$Ports       = [ordered]@{ Blob = 10000; Queue = 10001; Table = 10002 }
$MonitorPort = 7072
$MonitorUrl  = "http://localhost:$MonitorPort"

$LocalAccount = 'devstoreaccount1'

# ------------------------------------------------------------------ .env

# compose.yaml takes the monitor's connection string from .env, so every compose command needs the file.
function Initialize-EnvFile {
    if (Test-Path -LiteralPath $EnvFile) { return }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.env.example') -Destination $EnvFile
    Write-Ok "Created $EnvFile. The monitor shows the local Azurite until you change it."
}

# What the monitor's connection string in .env points at. Only the settings named here are kept:
# the rest of that line holds the key or SAS token.
function Get-MonitorStorage {
    $line = Get-Content -LiteralPath $EnvFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*STORAGE_CONNECTION_STRING\s*=' } | Select-Object -Last 1
    # The value, without a trailing comment or the quotes around it
    $value = ("$line" -replace '^[^=]*=' -replace '\s+#.*$').Trim().Trim('"', "'")

    $settings = @{}
    foreach ($pair in $value -split ';') {
        $name, $setting = $pair -split '=', 2
        $name = $name.Trim()
        if ($name -in 'DefaultEndpointsProtocol', 'AccountName', 'EndpointSuffix', 'BlobEndpoint', 'QueueEndpoint', 'TableEndpoint') {
            $settings[$name] = "$setting".Trim()
        }
    }

    $account  = $settings['AccountName']
    $protocol = if ($settings['DefaultEndpointsProtocol']) { $settings['DefaultEndpointsProtocol'] } else { 'https' }
    $suffix   = if ($settings['EndpointSuffix']) { $settings['EndpointSuffix'] } else { 'core.windows.net' }

    # An endpoint in the string wins, else it follows from the account. With neither it isn't listed.
    $endpoints = [ordered]@{}
    foreach ($service in $Ports.Keys) {
        $endpoint = $settings["${service}Endpoint"]
        if ($endpoint) {
            $endpoints[$service] = $endpoint -replace '\?.*$'   # a query string could be a SAS token
        } elseif ($account) {
            $endpoints[$service] = "${protocol}://${account}.$($service.ToLower()).${suffix}"
        }
    }

    return [pscustomobject]@{
        Account   = if ($account) { $account } else { 'see .env' }
        # By name and host: an account elsewhere can have the same name
        IsLocal   = $account -eq $LocalAccount -and $settings['BlobEndpoint'] -match "^https?://${Container}[:/]"
        Endpoints = $endpoints
    }
}

# Yellow when it isn't the local Azurite: the monitor has no sign-in and can change what it shows.
function Write-MonitorInfo([string]$Indent, $Storage) {
    $line = "${Indent}Monitor   : $MonitorUrl  (account: $($Storage.Account))"
    if ($Storage.IsLocal) { Write-Host $line } else { Write-Host $line -ForegroundColor Yellow }
}

function Get-PortsText {
    return (@($Ports.Keys | ForEach-Object { "$($_.ToLower()) $($Ports[$_])" }) -join ', ')
}

# The monitor reads another account, so that account comes first. Azurite keeps running, so it is
# still listed, as the separate thing it is. The connection string itself holds the key: never print it.
function Write-OtherAccountInfo([string]$Indent, $Storage) {
    Write-MonitorInfo $Indent $Storage
    foreach ($service in $Storage.Endpoints.Keys) {
        Write-Host ("${Indent}{0,-9} : {1}" -f $service, $Storage.Endpoints[$service])
    }
    Write-Host "${Indent}Conn str  : STORAGE_CONNECTION_STRING in $EnvFile"
    Write-Host "${Indent}Azurite   : separate local emulator, not used by the monitor" -ForegroundColor DarkGray
    Write-Host "${Indent}Ports     : $(Get-PortsText)" -ForegroundColor DarkGray
    Write-Host "${Indent}Data      : $DataDir" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ docker helpers

function Invoke-Compose { & docker compose -f $ComposeFile @args }

function Get-ContainerState([string]$Name) {
    $state = & docker inspect --format '{{.State.Status}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$state".Trim()
}

function Get-StatusText {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'Docker not installed' }
    & docker version --format '{{.Server.Version}}' *> $null
    if ($LASTEXITCODE -ne 0) { return 'Docker not running' }
    $states = [ordered]@{}
    foreach ($name in $Container, $Monitor) { $states[$name] = Get-ContainerState $name }
    if (-not ($states.Values | Where-Object { $_ })) { return 'not installed' }
    return (@($states.Keys | ForEach-Object {
                $state = $states[$_]
                if (-not $state) { $state = 'not installed' }
                "$_ ($state)"
            }) -join ', ')
}

# The previous version of this script created the azurite container with docker run. Compose can't
# take that container over, so it is removed; the data folder stays.
function Remove-OldContainer {
    $labels = & docker inspect --format '{{json .Config.Labels}}' $Container 2>$null
    if ($LASTEXITCODE -ne 0 -or "$labels" -match 'com\.docker\.compose\.project') { return }
    Write-Info "Removing the '$Container' container made by the previous version of this script (data stays)..."
    & docker stop $Container | Out-Null
    & docker rm $Container | Out-Null
}

# HTTP status from a local port, or 0 when nothing answers. Docker's port forwarder accepts
# connections before the service inside listens, so a plain TCP check isn't enough.
function Get-HttpStatus([int]$Port) {
    $ProgressPreference = 'SilentlyContinue'
    try {
        return [int](Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 3).StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# Azurite answers as soon as it listens (with an error status: requests must be signed).
# The monitor counts once it serves its page (200), so an error page from its Functions host doesn't.
function Wait-Ready([int]$TimeoutSeconds = 120) {
    Write-Host '  Waiting for Azurite and the monitor to answer' -NoNewline -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($name in $Container, $Monitor) {
            $state = Get-ContainerState $name
            if ($state -ne 'running') {
                Write-Host ''
                Write-Err "Container '$name' is not running (state: $state). Last lines of its log:"
                & docker logs --tail 25 $name 2>&1 | ForEach-Object { Write-Host "    $_" }
                return $false
            }
        }
        $azuriteUp = @($Ports.Values | Where-Object { (Get-HttpStatus $_) -eq 0 }).Count -eq 0
        if ($azuriteUp -and (Get-HttpStatus $MonitorPort) -eq 200) {
            Write-Host ' ready.' -ForegroundColor Green
            return $true
        }
        Write-Host '.' -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    }
    Write-Host ''
    Write-Err "Not ready within $TimeoutSeconds seconds."
    Write-Warn "Check the logs with: docker compose -f `"$ComposeFile`" logs"
    return $false
}

function Show-ConnectionInfo {
    Write-Host ''
    $storage = Get-MonitorStorage
    if (-not $storage.IsLocal) { Write-OtherAccountInfo '  ' $storage; return }
    foreach ($service in $Ports.Keys) {
        Write-Host ('  {0,-9} : http://127.0.0.1:{1}/devstoreaccount1' -f $service, $Ports[$service])
    }
    Write-Host '  Conn str  : UseDevelopmentStorage=true'
    Write-MonitorInfo '  ' $storage
    Write-Host "  Data      : $DataDir"
}

# ------------------------------------------------------------------ menu actions

function Install-Azurite {
    if (-not (Test-Docker)) { return }
    Remove-OldContainer

    # Ports of the containers that aren't running yet must be free
    $needed = @()
    if ((Get-ContainerState $Container) -ne 'running') { $needed += @($Ports.Values) }
    if ((Get-ContainerState $Monitor) -ne 'running') { $needed += $MonitorPort }
    $busy = @($needed | Where-Object { Test-PortInUse $_ })
    if ($busy.Count -gt 0) {
        Write-Err "Already in use on this PC: port $($busy -join ', ')."
        Write-Warn 'Stop whatever is using it (often another Azurite, like the one Visual Studio starts) and try again.'
        return
    }

    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    # Also when both are running: compose recreates only what .env or compose.yaml changed
    Write-Info 'Starting or updating Azurite and Durable Functions Monitor (the first run downloads the images)...'
    Invoke-Compose up -d
    if ($LASTEXITCODE -ne 0) { Write-Err 'docker compose up failed (see the messages above).'; return }

    if (Wait-Ready) { Show-ConnectionInfo }
}

function Uninstall-Azurite {
    if (-not (Test-Docker)) { return }
    if (-not (Get-ContainerState $Container) -and -not (Get-ContainerState $Monitor)) {
        Write-Info 'Azurite and Durable Functions Monitor are not installed.'
    } else {
        Write-Warn "This removes the '$Container' and '$Monitor' containers. Your data stays in $DataDir."
        if ((Read-Host '  Continue? (y/N)') -notmatch '^(y|yes)$') { Write-Info 'Cancelled.'; return }
        Remove-OldContainer
        Invoke-Compose down
        if ($LASTEXITCODE -ne 0) { Write-Err 'docker compose down failed (see the messages above).'; return }
        Write-Ok 'Containers removed. Option 1 creates them again with the same data.'
    }

    $images = @(Invoke-Compose config --images | Where-Object { & docker image inspect $_ *> $null; $LASTEXITCODE -eq 0 })
    if ($images.Count -gt 0) {
        if ((Read-Host "  Also delete the images $($images -join ', ') to free disk space? (y/N)") -match '^(y|yes)$') {
            & docker rmi @images
        }
    }
}

function Open-Monitor {
    if (-not (Test-Docker)) { return }
    if ((Get-ContainerState $Monitor) -ne 'running') {
        Write-Warn 'Durable Functions Monitor is not running - use option 1 to install or start it.'
        return
    }
    Write-Info "Opening $MonitorUrl in your browser..."
    Start-Process $MonitorUrl
}

# ------------------------------------------------------------------ menu

function Show-Menu {
    $status = Get-StatusText
    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '   Azurite + Durable Functions Monitor (Docker Compose)'
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host "   Status    : $status"
    $storage = Get-MonitorStorage
    if ($storage.IsLocal) {
        Write-Host "   Ports     : $(Get-PortsText)"
        Write-MonitorInfo '   ' $storage
        Write-Host "   Data      : $DataDir"
    } else {
        Write-OtherAccountInfo '   ' $storage
    }
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   1) Install Azurite and Durable Functions Monitor,'
    Write-Host '      or apply changes in .env'
    Write-Host '   2) Uninstall (data is kept)'
    Write-Host '   3) Open Durable Functions Monitor in the browser'
    if ($FromDevMenu) { Write-Host '   Q) Back to the dev menu' } else { Write-Host '   Q) Quit' }
    Write-Host ''
}

function Start-Menu {
    $actions = @{
        '1' = 'Install-Azurite'
        '2' = 'Uninstall-Azurite'
        '3' = 'Open-Monitor'
    }
    while ($true) {
        Initialize-EnvFile
        Show-Menu
        $choice = Read-MenuKey
        if ($null -eq $choice) { return }   # input closed
        if ($choice -eq 'q') { if (-not $FromDevMenu) { Write-Host '  Bye.' }; return }
        if (-not $actions.ContainsKey($choice)) { Write-Warn 'Choose 1, 2, 3 or Q.'; continue }

        Write-Host ''
        try {
            & $actions[$choice]
        } catch {
            Write-Err "Unexpected error: $($_.Exception.Message)"
        }
        Write-Host ''
        Wait-AnyKey
        Clear-Screen
    }
}

# Dot-sourcing (. .\azurite.ps1) only loads the functions; running the script opens the menu.
if ($MyInvocation.InvocationName -ne '.') {
    Start-Menu
}
