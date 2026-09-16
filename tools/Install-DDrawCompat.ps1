<#
.SYNOPSIS
    Install-DDrawCompat.ps1 - deploy DDrawCompat v0.7.1 as the game's
    authoritative DirectDraw layer.

.DESCRIPTION
    This is the FINAL architecture of the project (replaces the earlier
    DxWnd/pal-ddraw/dgVoodoo deployments):

      game folder ddraw.dll  =  DDrawCompat (DirectDraw/D3D1-7 -> D3D11 on GPU)
      mss32 proxy            =  music fix (unchanged)
      DxWnd                  =  NOT USED ANYMORE

    Why DDrawCompat (evidence in TROUBLESHOOTING.md section 5):
      - the in-level loadout draws its head icons as 128x128 ARGB4444
        alpha-blended sprites; DxWnd's HAL path renders them white
        (measured 24.5% HUD white) and DxWnd's author never shipped a
        complete fix (his thread ends mid-investigation, 2024-08-15)
      - DDrawCompat's own D3D11 pipeline renders the same textures with
        correct alpha, on the GPU: measured 0% HUD white, 2962 colors,
        crisp flat-pair 56.8% (baseline-level, i.e. hardware quality)

    Also retires leftovers of previous wrappers from the game folder
    (dgVoodoo D3DImm.dll / dgVoodoo.conf, retired pal-ddraw copies) so
    ddraw.dll is the single, verified DirectDraw layer.

.PARAMETER GameDir
    Game folder. Default C:\GAMES\HEDZ

.PARAMETER Check
    Verify the deployment only; change nothing.
#>
[CmdletBinding()]
param(
    [string]$GameDir = 'C:\GAMES\HEDZ',
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$kit    = $PSScriptRoot
$srcDll = Join-Path $kit 'ddrawcompat\dist\ddraw.dll'
$dest   = Join-Path $GameDir 'ddraw.dll'

if(-not (Test-Path $srcDll)){ throw 'DDrawCompat not found under tools\ddrawcompat\dist - run the download step in README section 4 first' }

$srcHash = (Get-FileHash $srcDll -Algorithm SHA256).Hash
$srcLen  = (Get-Item $srcDll).Length

if($Check){
    if(Test-Path $dest){
        $h=(Get-FileHash $dest -Algorithm SHA256).Hash
        Write-Host ("  ddraw.dll      : {0:N0} bytes  hash match: {1}" -f (Get-Item $dest).Length,($h -eq $srcHash))
    } else { Write-Host '  ddraw.dll      : MISSING' }
    return
}

Write-Host '=== deploying DDrawCompat v0.7.1 ==='
Copy-Item $srcDll $dest -Force
$dh=(Get-FileHash $dest -Algorithm SHA256).Hash
$dl=(Get-Item $dest).Length
if($dh -ne $srcHash -or $dl -ne $srcLen){
    throw ("ddraw.dll verify FAILED after deploy ({0} bytes, hash match {1})" -f $dl,($dh -eq $srcHash))
}
Write-Host ("  ddraw.dll deployed and verified: {0:N0} bytes, SHA256 match" -f $dl)

Write-Host '=== retiring leftover wrapper files (single-layer rule) ==='
foreach($f in 'D3DImm.dll','dgVoodoo.conf','ddraw.ini','DDraw.dll.pal-ddraw-disabled','DDRAW.dll.pal-ddraw-disabled'){
    $p = Join-Path $GameDir $f
    if(Test-Path $p){
        Remove-Item $p -Force
        Write-Host ("  removed {0}" -f $f)
    }
}
# any other DDRAW.dll variant in the folder (case-insensitive) must not survive
Get-ChildItem $GameDir -File | Where-Object {
    $_.Name -match '^(?i)ddraw\.dll\..*' -or ($_.Name -ieq 'ddraw.dll' -and $_.FullName -ne $dest)
} | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-Host ("  removed stray {0}" -f $_.Name)
}

Write-Host ''
Write-Host '=== how to run it ==='
Write-Host '  double-click tools\Run-Hedz.cmd        (or: powershell -File tools\Run-Hedz.ps1)'
Write-Host '  verify anytime with:  powershell -File tools\Get-HedzStatus.ps1'
