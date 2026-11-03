<#
.SYNOPSIS
    Artemis37 dev menu: opens the menu of each dev tool kept in this folder.

.DESCRIPTION
    Every tool lives in its own folder with its own script, settings (.env) and README.md.
    Press a tool's key to open its menu; Q there comes back here. README.md lists the tools.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\dev.ps1
#>

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'common.ps1')

# Key -> tool. Each script runs its own menu and returns here when Q is pressed.
$Modules = [ordered]@{
    '1' = @{ Name = 'SQL Server'; About = 'SQL Server in Docker, databases kept on this PC'; Script = 'sqlserver\sqlserver.ps1' }
    '2' = @{ Name = 'Azurite';    About = 'Azure Storage emulator (blob, queue, table) in Docker'; Script = 'azurite\azurite.ps1' }
}

# '#' is drawn as a full block; the file itself stays ASCII so Windows PowerShell reads it correctly.
$Banner = @'
 #####  ######  ######## ####### ###    ### ## ####### ######  #######
##   ## ##   ##    ##    ##      ####  #### ## ##           ##      ##
####### ######     ##    #####   ## #### ## ## #######  #####      ##
##   ## ##   ##    ##    ##      ##  ##  ## ##      ##      ##    ##
##   ## ##   ##    ##    ####### ##      ## ## ####### ######     ##
'@

function Show-Menu {
    $colors = 'Cyan', 'DarkCyan', 'Blue', 'DarkMagenta', 'Magenta'
    $lines = @($Banner -split "`r?`n")
    Write-Host ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        Write-Host ('  ' + ($lines[$i] -replace '#', [char]0x2588)) -ForegroundColor $colors[$i % $colors.Count]
    }
    Write-Host ''
    Write-Host '   Dev menu' -ForegroundColor DarkGray
    Write-Host '  ----------------------------------------------------------------------' -ForegroundColor DarkCyan
    foreach ($key in $Modules.Keys) {
        $module = $Modules[$key]
        Write-Host ('   {0}) {1,-12}' -f $key, $module.Name) -NoNewline
        Write-Host $module.About -ForegroundColor DarkGray
    }
    Write-Host '   Q) Quit'
    Write-Host ''
}

function Start-DevMenu {
    while ($true) {
        Clear-Screen
        Show-Menu
        $choice = Read-MenuKey
        while ($null -ne $choice -and $choice -ne 'q' -and -not $Modules.Contains($choice)) {
            Write-Warn "Choose $(@($Modules.Keys) -join ', ') or Q."
            $choice = Read-MenuKey
        }
        if ($null -eq $choice) { return }   # input closed
        if ($choice -eq 'q') { Write-Host '  Bye.'; return }

        Clear-Screen
        try {
            & (Join-Path $PSScriptRoot $Modules[$choice].Script) -FromDevMenu
        } catch {
            Write-Err "Unexpected error: $($_.Exception.Message)"
            Wait-AnyKey
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $previousEncoding = $null
    try { $previousEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try {
        Start-DevMenu
    } finally {
        if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
    }
}
