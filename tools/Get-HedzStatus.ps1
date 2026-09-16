<#
.SYNOPSIS
    Get-HedzStatus.ps1 - one-screen summary of the current H.E.D.Z. setup state.

.DESCRIPTION
    Answers, without changing anything:
      * which DirectDraw provider is in the game folder (pal-ddraw vs none)
      * whether DxWnd is deployed and which profile is installed
      * whether DxWnd / Hedz are running right now
      * whether the registry CD path is correct
      * whether the CD image is mounted and readable
      * any dxwnd.log present in the game folder

    Read-only.
#>
$ErrorActionPreference='Continue'
$gameDir='C:\GAMES\HEDZ'
$kit=$PSScriptRoot

function Line([string]$s){ Write-Host $s }

Line '=== game folder DirectDraw layer ==='
foreach($f in 'DDRAW.dll','DDRAW.dll.pal-ddraw-disabled','ddraw.ini','ddraw.dll','winmm.dll','winmm_real.dll'){
    $p=Join-Path $gameDir $f
    if(Test-Path $p){ Line ("  {0,-32} PRESENT   {1,10:N0} bytes" -f $f,(Get-Item $p).Length) }
    else { Line ("  {0,-32} -" -f $f) }
}

Line ''
Line '=== processes ==='
foreach($n in 'Hedz','dxwnd'){
    $ps=Get-Process -Name $n -ErrorAction SilentlyContinue
    if($ps){ $ps | ForEach-Object { Line ("  {0,-8} pid {1,-8} started {2:HH:mm:ss}" -f $_.ProcessName,$_.Id,$_.StartTime) } }
    else { Line ("  {0,-8} not running" -f $n) }
}

Line ''
Line '=== DxWnd deployment ==='
$rt=Join-Path $kit 'dxwnd\runtime'
Line ("  runtime dir        : {0}  ({1})" -f $rt, $(if(Test-Path $rt){'present'}else{'MISSING'}))
$prof=Join-Path $kit 'dxwnd\HEDZ.dxw'
Line ("  profile            : {0}  ({1})" -f $prof, $(if(Test-Path $prof){'present'}else{'MISSING'}))
if(Test-Path $prof){
    $t=Get-Content $prof -Raw
    foreach($k in 'title0','path0','renderer0','maxddinterface0','sizx0','sizy0','flag0','flagj0','flagn0','notes0'){
        $m=[regex]::Match($t,('(?m)^{0}=(.*)$' -f $k))
        if($m.Success){ Line ("    {0,-16} {1}" -f $k,$m.Groups[1].Value.Trim()) }
    }
    $v=[regex]::Match($t,'(?m)^version=(.*)$')
    if($v.Success){ Line ("    {0,-16} {1}" -f 'stamp version',$v.Groups[1].Value.Trim()) }
}
$ini=Join-Path $rt 'dxwnd.ini'
if(Test-Path $ini){ Line '  dxwnd.ini:'; Get-Content $ini | ForEach-Object { Line ("    " + $_) } }

Line ''
Line '=== DxWnd log files ==='
$found=$false
foreach($d in $gameDir,$rt,$env:TEMP){
    if($d -and (Test-Path $d)){
        Get-ChildItem $d -Filter 'dxwnd*.log' -ErrorAction SilentlyContinue | ForEach-Object {
            Line ("  {0}  {1:N0} bytes  {2:HH:mm:ss}" -f $_.FullName,$_.Length,$_.LastWriteTime); $script:found=$true
        }
    }
}
if(-not $found){ Line '  (no dxwnd log present)' }

Line ''
Line '=== registry CD path (32-bit view) ==='
$k='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if(Test-Path $k){
    $p=Get-ItemProperty $k
    foreach($n in 'InstalledFromDrive','Language','InstallType','FullScreen','ResMode','MusicLevel','SoundLevel'){
        $v=$p.PSObject.Properties | Where-Object { $_.Name -eq $n }
        if($v){ Line ("  {0,-20} {1}" -f $n,$v.Value) }
    }
} else { Line '  key missing' }

Line ''
Line '=== CD / music ==='
$drv=$null
if((Test-Path $k)){
    $v=(Get-ItemProperty $k -Name InstalledFromDrive -ErrorAction SilentlyContinue).InstalledFromDrive
    if($v){ $drv=$v.ToString().TrimEnd('\') }
}
if($drv){
    Line ("  InstalledFromDrive : {0}" -f $drv)
    if(Test-Path ($drv + '\Hedz\Music')){
        $m=Get-ChildItem ($drv + '\Hedz\Music') -Filter '*.mus' -ErrorAction SilentlyContinue
        Line ("  music tracks found : {0}" -f @($m).Count)
        $m | Select-Object -First 8 | ForEach-Object { Line ("    {0,-12} {1,12:N0}" -f $_.Name,$_.Length) }
    } else { Line ("  {0}\Hedz\Music not reachable" -f $drv) }
} else { Line '  could not determine the CD drive from the registry' }
