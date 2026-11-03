<#
.SYNOPSIS
    Helpers shared by dev.ps1 and the module menus. Dot-source it from a module: . (Join-Path $PSScriptRoot '..\helper\common.ps1')
#>

# ------------------------------------------------------------------ output helpers

function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Ok  ([string]$Message) { Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  $Message" -ForegroundColor Yellow }
function Write-Err ([string]$Message) { Write-Host "  $Message" -ForegroundColor Red }

function Clear-Screen {
    if (-not [Console]::IsOutputRedirected) { try { Clear-Host } catch { } }
}

# ------------------------------------------------------------------ menu input

# True when keys can be read one at a time: a real console, not piped input or the ISE.
function Test-KeyInput {
    if ([Console]::IsInputRedirected) { return $false }
    try { [void]$Host.UI.RawUI.KeyAvailable; return $true } catch { return $false }
}

# Returns the menu choice as soon as a key is pressed (no Enter), lower-cased. Esc counts as Q.
# Without key input it reads a line instead, and returns $null once piped input runs out.
function Read-MenuKey([string]$Prompt = 'Choose an option') {
    if (-not (Test-KeyInput)) {
        $line = Read-Host "  $Prompt"
        if ($null -eq $line -or ([Console]::IsInputRedirected -and $line -eq '')) { return $null }
        return $line.Trim().ToLower()
    }
    $Host.UI.RawUI.FlushInputBuffer()   # ignore keys pressed while the last action was running
    Write-Host "  ${Prompt}: " -NoNewline
    do {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } while ([char]::IsControl($key.Character) -and $key.VirtualKeyCode -ne 27)   # skip Shift, Enter, arrows...
    if ($key.VirtualKeyCode -eq 27) { Write-Host 'Esc'; return 'q' }
    Write-Host $key.Character
    return "$($key.Character)".ToLower()
}

# Pause after an action so its output can be read. Piped input doesn't wait.
function Wait-AnyKey {
    if (-not (Test-KeyInput)) {
        if (-not [Console]::IsInputRedirected) { Read-Host '  Press Enter to return to the menu' | Out-Null }
        return
    }
    $Host.UI.RawUI.FlushInputBuffer()
    Write-Host '  Press any key to return to the menu' -NoNewline
    do {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } while ($key.VirtualKeyCode -in 16, 17, 18)   # Shift, Ctrl, Alt on their own
    Write-Host ''
}

# ------------------------------------------------------------------ docker

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

function Test-PortInUse([int]$Port) {
    try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) } catch { return $false }
}
