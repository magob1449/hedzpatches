<#
.SYNOPSIS
    Get-HedzStatus.ps1 - one-screen summary of the current H.E.D.Z. setup state.

.DESCRIPTION
    Answers, without changing anything:
      * which DirectDraw layer is in the game folder (DDrawCompat hash check)
      * whether the mss32 music proxy is deployed
      * whether Hedz.exe is running right now
      * whether the registry CD path is correct
      * whether the CD image is mounted and the .mus tracks are readable
      * latest DDrawCompat log (tail)

    Read-only.
#>
$ErrorActionPreference='Continue'
$gameDir='C:\GAMES\HEDZ'
$kit=$PSScriptRoot

function Line([string]$s){ Write-Host $s }

Line '=== DirectDraw layer (single-layer rule) ==='
$dd=Join-Path $gameDir 'ddraw.dll'
$src=Join-Path $kit 'ddrawcompat\dist\ddraw.dll'
if(Test-Path $dd){
    $len=(Get-Item $dd).Length
    $ok=$false
    if(Test-Path $src){ $ok=((Get-FileHash $dd -Algorithm SHA256).Hash -eq (Get-FileHash $src -Algorithm SHA256).Hash) }
    Line ("  ddraw.dll            PRESENT   {0,10:N0} bytes   DDrawCompat v0.7.1 hash match: {1}" -f $len,$ok)
} else {
    Line '  ddraw.dll            MISSING - run tools\Install-DDrawCompat.ps1'
}
foreach($f in 'DDrawCompat-Hedz.log','winmm.dll','winmm_real.dll','D3DImm.dll','dgVoodoo.conf','ddraw.ini'){
    $p=Join-Path $gameDir $f
    if(Test-Path $p){
        if($f -in 'D3DImm.dll','dgVoodoo.conf','ddraw.ini'){ Line ("  {0,-22} PRESENT  <-- LEFTOVER, run Install-DDrawCompat to remove" -f $f) }
        else { Line ("  {0,-22} PRESENT   {1,10:N0} bytes" -f $f,(Get-Item $p).Length) }
    }
}
$mss=Join-Path $gameDir 'MSS32.DLL'
$mr=Join-Path $gameDir 'mss32_real.dll'
if((Test-Path $mss) -and (Test-Path $mr)){ Line '  mss32 music proxy    PRESENT (streams .mus from the CD)' }
else { Line '  mss32 music proxy    MISSING' }

Line ''
Line '=== processes ==='
foreach($n in 'Hedz','dxwnd'){
    $ps=Get-Process -Name $n -ErrorAction SilentlyContinue
    if($ps){ $ps | ForEach-Object { Line ("  {0,-8} pid {1,-8} started {2:HH:mm:ss}" -f $_.ProcessName,$_.Id,$_.StartTime) } }
    else { Line ("  {0,-8} not running" -f $n) }
}
$dx=Get-Process -Name dxwnd -ErrorAction SilentlyContinue
if($dx){ Line '  NOTE: DxWnd is running - stop it (one-wrapper rule): the game no longer uses DxWnd' }

Line ''
Line '=== registry (32-bit view) ==='
$k='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if(Test-Path $k){
    $p=Get-ItemProperty $k
    foreach($n in 'InstalledFromDrive','ExecutableLocation','Language','InstallType','FullScreen','ResMode','MusicLevel','SoundLevel'){
        $v=$p.PSObject.Properties | Where-Object { $_.Name -eq $n }
        if($v){ Line ("  {0,-20} {1}" -f $n,$v.Value) }
    }
} else { Line '  key missing' }

Line ''
Line '=== CD / music ==='
$drv=$null
if(Test-Path $k){
    $v=(Get-ItemProperty $k -Name InstalledFromDrive -ErrorAction SilentlyContinue).InstalledFromDrive
    if($v){ $drv=$v.ToString().TrimEnd('\') }
}
if($drv){
    Line ("  InstalledFromDrive : {0}" -f $drv)
    if(Test-Path ($drv + '\Hedz\Music')){
        $m=Get-ChildItem ($drv + '\Hedz\Music') -Filter '*.mus' -ErrorAction SilentlyContinue
        Line ("  music tracks found : {0}" -f @($m).Count)
        $m | Select-Object -First 8 | ForEach-Object { Line ("    {0,-12} {1,12:N0}" -f $_.Name,$_.Length) }
    } else { Line ("  {0}\Hedz\Music not reachable - mount the CD image on {0}" -f $drv) }
} else { Line '  could not determine the CD drive from the registry' }

Line ''
Line '=== DDrawCompat log (tail) ==='
$lc=Join-Path $gameDir 'DDrawCompat-Hedz.log'
if(Test-Path $lc){
    Get-Content $lc -Tail 6 | ForEach-Object { Line ("  " + $_) }
} else { Line '  (no DDrawCompat log yet - it appears after the first game run)' }
