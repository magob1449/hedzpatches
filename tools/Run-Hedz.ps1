<#
.SYNOPSIS
    Run-Hedz.ps1 - the canonical way to launch H.E.D.Z. on Windows 11.

.DESCRIPTION
    FINAL architecture (DDrawCompat era, supersedes the DxWnd launcher):

      game folder ddraw.dll  =  DDrawCompat v0.7.1 (DirectDraw/D3D1-7 -> D3D11,
                                GPU rendering with correct ARGB4444 alpha
                                sprites - the loadout/HUD fix)
      mss32 proxy            =  music fix (streams .mus from the CD)
      DxWnd / pal-ddraw      =  retired; nothing else hooks the game

    Launch sequence:
      1. verify (or deploy) DDrawCompat ddraw.dll by SHA256
      2. check the CD is mounted and the .mus tracks are reachable
      3. start Hedz.exe directly - DDrawCompat emulates the display-mode
         path itself, so no window manager is needed

    The game opens a 640x480 window (fullscreen emulated by DDrawCompat).
    Measure/verify rendering with tools\Test-DDrawCompat.ps1 -MeasureOnly
    or tools\Get-HedzStatus.ps1.

.PARAMETER Wait
    Block until Hedz.exe exits.

.PARAMETER SkipDeploy
    Do not touch ddraw.dll; just verify it and launch.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$Wait,
    [switch]$SkipDeploy
)
$ErrorActionPreference='Stop'

$kit     = $PSScriptRoot
$gameDir = Split-Path $GameExe -Parent
$dd      = Join-Path $gameDir 'ddraw.dll'

function Say([string]$s){ Write-Host $s }

# ---------- preflight ----------
if(-not (Test-Path $GameExe)){ throw "Game not found: $GameExe" }

Say '=== DirectDraw layer (DDrawCompat) ==='
if(-not $SkipDeploy){
    & (Join-Path $kit 'Install-DDrawCompat.ps1') -GameDir $gameDir
} else {
    & (Join-Path $kit 'Install-DDrawCompat.ps1') -GameDir $gameDir -Check
}

# ---------- CD / music check ----------
Say ''
Say '=== CD check ==='
$cd = $null
$k='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if(Test-Path $k){ $cd=(Get-ItemProperty $k -Name InstalledFromDrive -ErrorAction SilentlyContinue).InstalledFromDrive }
if($cd){
    $cd=$cd.ToString().TrimEnd('\')
    if(Test-Path ($cd + '\Hedz\Music')){
        $n=@(Get-ChildItem ($cd + '\Hedz\Music') -Filter '*.mus' -ErrorAction SilentlyContinue).Count
        Say ("disc OK: {0}\Hedz\Music has {1} .mus tracks" -f $cd,$n)
    } else {
        Say ("WARNING: {0}\Hedz\Music is not reachable - mount the CD image on {0} first (music will be silent)" -f $cd)
    }
} else { Say 'WARNING: InstalledFromDrive not set - run tools\Set-HedzCdPath.ps1 -CdDrive D: (elevated)' }

# ---------- launch ----------
Say ''
Say '=== launching Hedz.exe (DDrawCompat active) ==='
$old = Get-Process -Name Hedz -ErrorAction SilentlyContinue
if($old){ Say ("stale Hedz.exe pid {0} found - stopping it first" -f $old.Id); $old | ForEach-Object { $_.Kill() }; Start-Sleep -Milliseconds 700 }

$p = Start-Process -FilePath $GameExe -WorkingDirectory $gameDir -PassThru
Say ("  pid {0} - the game opens a 640x480 window (fullscreen emulated by DDrawCompat)" -f $p.Id)

if($Wait){
    Say 'waiting for the game to exit...'
    while(-not $p.HasExited){ Start-Sleep -Seconds 2 }
    Say 'game exited.'
} else {
    Say ''
    Say 'To check rendering status later:'
    Say '    powershell -File tools\Get-HedzStatus.ps1'
}
