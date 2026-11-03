<#
.SYNOPSIS
    Menu to install and uninstall Azurite, the Azure Storage emulator, running in Docker.

.DESCRIPTION
    Azurite serves Blob, Queue and Table storage on the standard emulator ports, so apps connect with
    UseDevelopmentStorage=true. Its data lives in the data folder next to this script and is kept
    when Azurite is uninstalled:

        azurite\data -> /data

    There is no .env: the standard ports are what UseDevelopmentStorage=true expects. To change the
    container name, image or ports, edit the settings below.

    Requires Docker Desktop running Linux containers.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\azurite\azurite.ps1
#>

param(
    # Set by dev.ps1: Q goes back to the dev menu instead of quitting
    [switch]$FromDevMenu
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot '..\common.ps1')

$Container = 'azurite'
$Image     = 'mcr.microsoft.com/azure-storage/azurite'
$DataDir   = Join-Path $PSScriptRoot 'data'
$Ports     = [ordered]@{ Blob = 10000; Queue = 10001; Table = 10002 }

# ------------------------------------------------------------------ docker helpers

function Get-ContainerState {
    $state = & docker inspect --format '{{.State.Status}}' $Container 2>$null
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

# Any HTTP answer, even an error status (Azurite wants a signed request), means the service is up.
# Docker's port forwarder accepts connections before Azurite listens, so a plain TCP check isn't enough.
function Test-ServiceUp([int]$Port) {
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $null -ne $_.Exception.Response
    }
}

function Wait-AzuriteReady([int]$TimeoutSeconds = 60) {
    Write-Host '  Waiting for Azurite to answer' -NoNewline -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-ContainerState
        if ($state -ne 'running') {
            Write-Host ''
            Write-Err "The container is not running (state: $state). Last lines of its log:"
            & docker logs --tail 25 $Container 2>&1 | ForEach-Object { Write-Host "    $_" }
            return $false
        }
        if (@($Ports.Values | Where-Object { -not (Test-ServiceUp $_) }).Count -eq 0) {
            Write-Host ' ready.' -ForegroundColor Green
            return $true
        }
        Write-Host '.' -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Write-Err "Azurite did not answer within $TimeoutSeconds seconds."
    Write-Warn "Check the log with: docker logs $Container"
    return $false
}

function Show-ConnectionInfo {
    Write-Host ''
    foreach ($service in $Ports.Keys) {
        Write-Host ('  {0,-9} : http://127.0.0.1:{1}/devstoreaccount1' -f $service, $Ports[$service])
    }
    Write-Host '  Conn str  : UseDevelopmentStorage=true'
    Write-Host "  Data      : $DataDir"
}

# ------------------------------------------------------------------ menu actions

function Install-Azurite {
    if (-not (Test-Docker)) { return }
    $state = Get-ContainerState
    if ($state -eq 'running') {
        Write-Ok "Azurite is already installed and running (container '$Container')."
        Show-ConnectionInfo
        return
    }

    if ($state) {
        Write-Info "Starting the existing container '$Container'..."
        & docker start $Container | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Could not start the container. Uninstall Azurite, then install it again.'; return }
    } else {
        $busy = @($Ports.Values | Where-Object { Test-PortInUse $_ })
        if ($busy.Count -gt 0) {
            Write-Err "Already in use on this PC: port $($busy -join ', ') (another Azurite, maybe the one Visual Studio starts?)."
            Write-Warn 'Stop whatever is using it and try again.'
            return
        }

        & docker image inspect $Image *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Info "Downloading $Image (first time only)..."
            & docker pull $Image
            if ($LASTEXITCODE -ne 0) { Write-Err 'Image download failed.'; return }
        }

        if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        Write-Info "Creating container '$Container'..."
        # Published on 127.0.0.1 only: every Azurite has the same well-known account key.
        $publish = foreach ($port in $Ports.Values) { '-p'; "127.0.0.1:${port}:$port" }
        # --skipApiVersionCheck: newer Azure SDKs send API versions this Azurite may not know yet
        $out = & docker run -d --name $Container @publish -v "${DataDir}:/data" --restart unless-stopped $Image `
            azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 --location /data --skipApiVersionCheck 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'docker run failed:'
            $out | ForEach-Object { Write-Host "    $_" }
            & docker rm -f $Container *> $null
            return
        }
    }

    if (Wait-AzuriteReady) { Show-ConnectionInfo }
}

function Uninstall-Azurite {
    if (-not (Test-Docker)) { return }
    if (-not (Get-ContainerState)) {
        Write-Info "There is no container named '$Container'."
    } else {
        Write-Warn "This removes container '$Container'. Your data stays in $DataDir."
        if ((Read-Host '  Continue? (y/N)') -notmatch '^(y|yes)$') { Write-Info 'Cancelled.'; return }
        & docker stop $Container | Out-Null
        & docker rm $Container | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err 'Could not remove the container.'; return }
        Write-Ok 'Container removed. Option 1 creates it again with the same data.'
    }

    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        if ((Read-Host "  Also delete the image $Image to free disk space? (y/N)") -match '^(y|yes)$') {
            & docker rmi $Image
        }
    }
}

# ------------------------------------------------------------------ menu

function Show-Menu {
    $status = Get-StatusText
    Write-Host ''
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host '   Azurite (Azure Storage emulator) in Docker'
    Write-Host '  ================================================' -ForegroundColor DarkCyan
    Write-Host "   Container : $Container ($status)"
    Write-Host "   Ports     : $(($Ports.Keys | ForEach-Object { "$($_.ToLower()) $($Ports[$_])" }) -join ', ')"
    Write-Host "   Data      : $DataDir"
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   1) Install Azurite'
    Write-Host '   2) Uninstall (data is kept)'
    if ($FromDevMenu) { Write-Host '   Q) Back to the dev menu' } else { Write-Host '   Q) Quit' }
    Write-Host ''
}

function Start-Menu {
    $actions = @{
        '1' = 'Install-Azurite'
        '2' = 'Uninstall-Azurite'
    }
    while ($true) {
        Show-Menu
        $choice = Read-MenuKey
        if ($null -eq $choice) { return }   # input closed
        if ($choice -eq 'q') { if (-not $FromDevMenu) { Write-Host '  Bye.' }; return }
        if (-not $actions.ContainsKey($choice)) { Write-Warn 'Choose 1, 2 or Q.'; continue }

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
