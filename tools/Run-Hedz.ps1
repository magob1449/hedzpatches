<#
.SYNOPSIS
    Run-Hedz.ps1 - the canonical way to launch H.E.D.Z. on Windows 11.

.DESCRIPTION
    Launch sequence that works on this machine:

      1. (default) retire pal-ddraw - DxWnd is the single authoritative
         DirectDraw layer, and pal-ddraw provably does nothing for this title
         (verified: standing it down, and sweeping its config, both change
         nothing). Running both violates the one-wrapper rule.
      2. start the DxWnd server in the tray (quiet)
      3. hand it the official H.E.D.Z. profile with /Y:<file>
      4. optionally wait for the game to exit, then shut DxWnd down

    The official profile is what fixed the blocker: it forces the render window
    to 800x600 instead of the full desktop (1920x1080), which is the size the
    game could not allocate surfaces for - its own string says it all:
      "To run this program in a window of this size, please adjust your display
       settings for a smaller desktop area or a lower palette size..."

.PARAMETER KeepPalDdraw
    Leave the game folder's pal-ddraw DDRAW.dll in place (not recommended).

.PARAMETER Wait
    Block until Hedz.exe exits, then stop DxWnd.

.PARAMETER RestorePalDdraw
    Put pal-ddraw back after the session, for a clean return to the original
    state. Implies the game folder's ddraw.ini is left untouched.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$KeepPalDdraw,
    [switch]$Wait,
    [switch]$RestorePalDdraw
)
$ErrorActionPreference='Stop'

$kit   = $PSScriptRoot
$rt    = Join-Path $kit 'dxwnd\runtime'
$exe   = Join-Path $rt 'dxwnd.exe'
$prof  = Join-Path $kit 'dxwnd\HEDZ.dxw'
$gameDir = Split-Path $GameExe -Parent
$pdd   = Join-Path $gameDir 'DDRAW.dll'
$pddOff= Join-Path $gameDir 'DDRAW.dll.pal-ddraw-disabled'

function Say([string]$s){ Write-Host $s }

# ---------- preflight ----------
if(-not (Test-Path $exe)) { throw "DxWnd is not deployed. Run: powershell -File tools\Install-DxWnd.ps1" }
if(-not (Test-Path $prof)){ throw "Profile missing. Run: powershell -File tools\Install-DxWnd.ps1" }
if(-not (Test-Path $GameExe)){ throw "Game not found: $GameExe" }

# the disc must be reachable or the game will demand it
$cd = $null
$k='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if(Test-Path $k){ $cd=(Get-ItemProperty $k -Name InstalledFromDrive -ErrorAction SilentlyContinue).InstalledFromDrive }
if($cd){
    $cd=$cd.ToString().TrimEnd('\')
    if(Test-Path ($cd + '\Hedz\Music')){
        $n=@(Get-ChildItem ($cd + '\Hedz\Music') -Filter '*.mus' -ErrorAction SilentlyContinue).Count
        Say ("disc OK: {0}\Hedz\Music has {1} .mus tracks" -f $cd,$n)
    } else {
        Say ("WARNING: {0}\Hedz\Music is not reachable - mount the CD image on {0} first" -f $cd)
    }
} else { Say 'WARNING: InstalledFromDrive not set - run tools\Set-HedzCdPath.ps1 -CdDrive D: (elevated)' }

# ---------- one-wrapper rule ----------
$restore=$false
if(-not $KeepPalDdraw -and (Test-Path $pdd)){
    if(Test-Path $pddOff){ Remove-Item $pddOff -Force }
    Move-Item $pdd $pddOff -Force
    $restore=$true
    Say 'pal-ddraw retired for this session (DxWnd is the authoritative DirectDraw layer)'
}

# ---------- launch ----------
Say 'starting the DxWnd server...'
Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill(); }
Start-Sleep -Milliseconds 700
$server = Start-Process -FilePath $exe -ArgumentList '/T','/Q' -WorkingDirectory $rt -PassThru
Start-Sleep -Seconds 3
Say ("  server pid {0}" -f $server.Id)

Say ("running profile {0} ..." -f (Split-Path $prof -Leaf))
$client = Start-Process -FilePath $exe -ArgumentList ('/Y:"' + $prof + '"') -WorkingDirectory $rt -PassThru
$client.WaitForExit(20000) | Out-Null
Say '  game launched - look for an 800x600 window'

if($Wait){
    Say 'waiting for Hedz.exe to exit...'
    while(Get-Process -Name Hedz -ErrorAction SilentlyContinue){ Start-Sleep -Seconds 2 }
    Say 'game exited - stopping DxWnd'
    Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    if($restore -or $RestorePalDdraw){
        if(Test-Path $pddOff){ Move-Item $pddOff $pdd -Force; Say 'pal-ddraw restored' }
    }
} else {
    Say ''
    Say 'DxWnd stays in the system tray while you play.'
    Say 'To stop DxWnd afterwards:'
    Say ('    "{0}" /E' -f $exe)
}
