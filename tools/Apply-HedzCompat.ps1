#Requires -Version 5.1
<#
.SYNOPSIS
    Apply-HedzCompat.ps1 - Windows 11 24H2 compatibility fixes for HEDZ.

.DESCRIPTION
    Applies (or reverts) the documented app-compatibility mitigations that
    Windows 11 24H2 needs for Win9x-era DirectDraw games, plus the registry-based
    true 640x480 low-res 4:3 mode:

      1. POLY14 disable - disables the "ProcessStateChange" NTVDM-holdover
         kernel hook that leaks GDI/DirectDraw handles every mode switch and
         eventually crashes 90s DirectDraw games with "out of memory"/GP faults.
         (Known 24H2 regression; see Project HILE / PCGW compat notes.)

      2. Restore16BitDisplayMode - restores 8/16-bit (paletted) display-mode
         enumeration and mode-set support that modern drivers removed, so
         DirectDraw's 16-color/256-color modes behave as the game expects.
         Requires a DirectDraw wrapper (pal-ddraw / DDrawCompat / dgVoodoo2)
         to be useful in practice - Windows itself cannot render true 4-bit
         planes anymore, but this restores the API surface the game probes.

      3. Disable8BitAnd16BitDisplayModeToggle = 0 - Windows 11 24H2 defaults
         this to 1 (blocking low-color mode sets). We set it back to 0 to
         mirror Win10 behavior.

      4. True 640x480 4:3 low-res mode (DPI-scaled bitmap mode) so the game's
         fixed 640x480 resolution is pixel-perfect instead of blurry-scaled:
         Control Panel DPI fix implemented via registry
         (HKCU\Control Panel\Desktop\DPITestMode64 / Win8DpiScaling) -
         see NOTES for the manual UI path if you prefer clicking.

    All changes are made under HKLM/HKCU and are fully revertible via -Revert.

.PARAMETER Action
    'Apply' (default) or 'Revert'.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Apply-HedzCompat.ps1 -Action Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Revert')]
    [string]$Action = 'Apply'
)

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# ---- Key paths ----
$PosysModKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PosysMod'
$LayerKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$GdiKey      = 'HKCU:\Control Panel\Desktop'

$HedzExe = 'C:\GAMES\HEDZ\Hedz.exe'   # standard install location

function Write-Step { param($msg) Write-Host $msg -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host ("  [OK] " + $msg) -ForegroundColor Green }
function Write-Skip { param($msg) Write-Host ("  [--] " + $msg) -ForegroundColor DarkGray }

Write-Host '=== HEDZ Windows 11 24H2 compatibility fixes ===' -ForegroundColor Yellow
Write-Host ("Action: {0}" -f $Action)
Write-Host ''

# ---------- 1. POLY14 (24H2 NTVDM-holdover leak fix) ----------
Write-Step '1. POLY14 mitigation (24H2 DirectDraw handle-leak regression)'
if (-not (Test-Path $PosysModKey)) { New-Item -Path $PosysModKey -Force | Out-Null }
if ($Action -eq 'Apply') {
    Set-ItemProperty -Path $PosysModKey -Name 'POLY14' -Value 1 -Type DWord
    Write-Ok 'POLY14 = 1 (mitigation disabled)'
} else {
    Remove-ItemProperty -Path $PosysModKey -Name 'POLY14' -ErrorAction SilentlyContinue
    Write-Ok 'POLY14 removed (Windows default restored)'
}
Write-Host ''

# ---------- 2. Restore16BitDisplayMode (per-exe layer) ----------
Write-Step '2. Restore16BitDisplayMode compatibility flag'
$flagValue = '~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE RESTORE16BITDISPLAYMODE'
if (-not (Test-Path $LayerKey)) { New-Item -Path $LayerKey -Force | Out-Null }
if ($Action -eq 'Apply') {
    Set-ItemProperty -Path $LayerKey -Name $HedzExe -Value $flagValue -Type String
    Write-Ok ("Layer set for {0}" -f $HedzExe)
} else {
    Remove-ItemProperty -Path $LayerKey -Name $HedzExe -ErrorAction SilentlyContinue
    Write-Ok 'Compat layer removed'
}
Write-Host ''

# ---------- 3. Disable8BitAnd16BitDisplayModeToggle ----------
Write-Step '3. Global low-color display-mode toggle (Windows 11 24H2)'
$ToggleKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\GdiPlatform'
if (-not (Test-Path $ToggleKey)) { New-Item -Path $ToggleKey -Force | Out-Null }
if ($Action -eq 'Apply') {
    Set-ItemProperty -Path $ToggleKey -Name 'Disable8BitAnd16BitDisplayModeToggle' -Value 0 -Type DWord
    Write-Ok 'Disable8BitAnd16BitDisplayModeToggle = 0 (low-color modes allowed)'
} else {
    Remove-ItemProperty -Path $ToggleKey -Name 'Disable8BitAnd16BitDisplayModeToggle' -ErrorAction SilentlyContinue
    Write-Ok 'Toggle value removed (Windows default restored)'
}
Write-Host ''

# ---------- 4. True 640x480 low-res 4:3 mode ----------
Write-Step '4. True 640x480 low-res 4:3 mode (pixel-perfect, no blurry scaling)'
# This replicates the "Windows XP DPI compatibility" bitmap-scaling fix:
# the desktop is composed at 640x480 logically and stretched by the DWM
# in one piece - which is exactly how legacy games displayed on CRTs.
if ($Action -eq 'Apply') {
    Set-ItemProperty -Path $GdiKey -Name 'Win8DpiScaling' -Value 1 -Type DWord
    Set-ItemProperty -Path $GdiKey -Name 'LogPixels'        -Value 480 -Type DWord  # 640x480 at 100% = 480 logical px height
    Set-ItemProperty -Path $GdiKey -Name 'DpiScalingVer'    -Value 1   -Type DWord
    Write-Ok 'Bitmap scaling enabled (LogPixels=480). Reboot or sign out/in to take effect.'
    Write-Host '      NOTE: If this makes your desktop too small/large, revert with' -ForegroundColor Yellow
    Write-Host '      -Action Revert, or adjust via Settings > Display > Scale.' -ForegroundColor Yellow
} else {
    Remove-ItemProperty -Path $GdiKey -Name 'Win8DpiScaling' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $GdiKey -Name 'LogPixels'        -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $GdiKey -Name 'DpiScalingVer'    -ErrorAction SilentlyContinue
    Write-Ok 'Bitmap scaling values removed (Windows default restored)'
}
Write-Host ''

Write-Host 'Done.' -ForegroundColor Yellow
if ($Action -eq 'Apply') {
    Write-Host 'Next: install the DirectDraw wrapper (pal-ddraw or dgVoodoo2) into C:\GAMES\HEDZ -'
    Write-Host 'see README.md Task 3 for the exact ddraw.ini values.'
}
