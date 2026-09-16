<#
.SYNOPSIS
    Install-DxWnd.ps1 - deploys the DxWnd runtime from the extracted official
    distribution and installs the OFFICIAL H.E.D.Z. profile.

.DESCRIPTION
    DxWnd 2.06.15 ships two ready-made H.E.D.Z. profiles in its exports folder:
    "HEDZ.dxw" (maintained, stamped v2.04.72.a0) and "H.E.D.Z..dxw" (older).
    The maintained one carries a note that is directly relevant here:

        To see the menu text the "Set texture pixel format" flag must be set

    Those profiles reference the author's install path, so this copies the
    maintained profile into the kit and rewrites only the executable path.

    An earlier revision of tools\dxwnd\HEDZ.dxw was hand-written with invented
    key names (ForceSurfaceUnlock, PartialFlipEmulation, ...). DxWnd does NOT
    use such keys - it stores bitmasks (flag0, flagg0, flagh0 ...). That file
    has been replaced; do not reintroduce hand-invented keys.

.PARAMETER GameExe
    Path to Hedz.exe on this machine. Default C:\GAMES\HEDZ\Hedz.exe

.PARAMETER DisablePalDdraw
    Rename the game folder's pal-ddraw DDRAW.dll out of the way, so DxWnd is the
    single authoritative DirectDraw layer (the project's one-wrapper rule).

.PARAMETER RestorePalDdraw
    Undo DisablePalDdraw.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$DisablePalDdraw,
    [switch]$RestorePalDdraw
)

$ErrorActionPreference='Stop'
$kit   = $PSScriptRoot
$dist  = Join-Path $kit 'dxwnd\dist'
$rt    = Join-Path $kit 'dxwnd\runtime'
$gameDir = Split-Path $GameExe -Parent
$pdd   = Join-Path $gameDir 'DDRAW.dll'
$pddOff= Join-Path $gameDir 'DDRAW.dll.pal-ddraw-disabled'

if(-not (Test-Path $dist)){ throw "extracted DxWnd distribution not found at $dist - extract v2_06_15_build.rar there first" }

# ---------- 1. deploy runtime (everything except the big help/ and exports/ trees) ----------
Write-Host '=== deploying DxWnd runtime ==='
if(-not (Test-Path $rt)){ New-Item -ItemType Directory -Path $rt -Force | Out-Null }
$skipDirs = 'exports','help'
$n=0
foreach($item in Get-ChildItem $dist){
    if($item.PSIsContainer -and ($skipDirs -contains $item.Name)){ continue }
    if($item.PSIsContainer){
        Copy-Item $item.FullName (Join-Path $rt $item.Name) -Recurse -Force
    } else {
        Copy-Item $item.FullName $rt -Force
    }
    $n++
}
Write-Host ("  copied {0} top-level items to {1}" -f $n,$rt)
foreach($must in 'dxwnd.exe','dxwnd.dll','MinHook.x86.dll'){
    $p=Join-Path $rt $must
    Write-Host ("  {0,-18} {1}" -f $must, $(if(Test-Path $p){ ('{0:N0} bytes' -f (Get-Item $p).Length) } else { 'MISSING!' }))
}

# ---------- 2. install the official profile ----------
Write-Host ''
Write-Host '=== installing the official H.E.D.Z. profile ==='
$srcProfile = Join-Path $dist 'exports\HEDZ.dxw'
if(-not (Test-Path $srcProfile)){ throw "official HEDZ.dxw not found in the distribution" }
$text = Get-Content $srcProfile -Raw
Write-Host ("  source profile: {0}" -f $srcProfile)
$origPath = ([regex]::Match($text,'(?m)^path0=(.*)$')).Groups[1].Value.Trim()
Write-Host ("  original path0 : {0}" -f $origPath)
$text = [regex]::Replace($text,'(?m)^path0=.*$', ('path0=' + $GameExe))
if(-not (Test-Path $GameExe)){ Write-Host ("  WARNING: {0} does not exist on this machine" -f $GameExe) }

$destProfile = Join-Path $kit 'dxwnd\HEDZ.dxw'
[IO.File]::WriteAllText($destProfile,$text)
Write-Host ("  installed      : {0}" -f $destProfile)
Write-Host '  key settings carried over from the official profile:'
foreach($k in 'title0','path0','ver0','renderer0','maxddinterface0','sizx0','sizy0','flag0','flagg0','flagh0','flagi0','flagj0','flagk0','flagn0','notes0'){
    $m=[regex]::Match($text,('(?m)^{0}=(.*)$' -f $k))
    if($m.Success){ Write-Host ("    {0,-18} {1}" -f $k,$m.Groups[1].Value.Trim()) }
}

# ---------- 3. one-wrapper rule ----------
Write-Host ''
Write-Host '=== DirectDraw layer bookkeeping ==='
if($RestorePalDdraw){
    if(Test-Path $pddOff){ Move-Item $pddOff $pdd -Force; Write-Host '  pal-ddraw RESTORED (DDRAW.dll active again)' }
    else { Write-Host '  nothing to restore' }
}
if($DisablePalDdraw){
    if(Test-Path $pdd){
        if(Test-Path $pddOff){ Remove-Item $pddOff -Force }
        Move-Item $pdd $pddOff -Force
        Write-Host ("  pal-ddraw disabled: DDRAW.dll -> {0}" -f (Split-Path $pddOff -Leaf))
    } elseif(Test-Path $pddOff){ Write-Host '  pal-ddraw already disabled' }
    else { Write-Host '  no DDRAW.dll in the game folder' }
}
Write-Host ("  game folder DDRAW.dll present: {0}" -f (Test-Path $pdd))
Write-Host ("  game folder ddraw.ini present : {0}" -f (Test-Path (Join-Path $gameDir 'ddraw.ini')))

Write-Host ''
Write-Host '=== how to run it ==='
Write-Host '  Canonical launcher (recommended):'
Write-Host '      powershell -File tools\Run-Hedz.ps1        (or double-click tools\Run-Hedz.cmd)'
Write-Host '  Diagnostics:'
Write-Host '      powershell -File tools\Test-DxWnd.ps1       (measures the window, restores pal-ddraw)'
Write-Host '      powershell -File tools\Get-HedzStatus.ps1   (read-only state check)'
Write-Host '  By hand:'
Write-Host ('      {0} /T /Q' -f (Join-Path $rt 'dxwnd.exe'))
Write-Host ('      {0} /Y:"{1}"' -f (Join-Path $rt 'dxwnd.exe'), $destProfile)
