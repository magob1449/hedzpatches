#Requires -Version 5.1
<#
.SYNOPSIS
    Inspect-Movies.ps1 - characterise the H.E.D.Z. intro/cutscene movies and the
    TruePlay.dll module the game uses to decode them.

.DESCRIPTION
    The game opens D:\Hedz\Movies\VISident.avi right after the CD check passes,
    then idles for ~8 s burning no CPU and exits cleanly. That is the intro
    movie path (crash class C2 in the diagnosis). This reports:

      * every file in the disc's Movies folder with size
      * the RIFF/AVI header of each .avi: is it a normal AVI, and which video
        fourcc does it declare? (a missing/legacy codec looks exactly like this)
      * TruePlay.dll identity: version resource, imports, exports, and strings
        that hint at codec names or CPU-feature/protection requirements
      * whether the game has a switch or setting to skip movies

    Read-only.
#>
[CmdletBinding()]
param(
    [string]$MoviesDir = 'D:\Hedz\Movies',
    [string]$GameDir   = 'C:\GAMES\HEDZ'
)

$ErrorActionPreference = 'Continue'

function FourCC4($b, $o) { return [Text.Encoding]::ASCII.GetString($b, $o, 4) }

Write-Host '=== 1. disc Movies folder ===' -ForegroundColor Cyan
if (Test-Path $MoviesDir) {
    Get-ChildItem $MoviesDir -File | Sort-Object Name |
        ForEach-Object { Write-Host ("  {0,-24} {1,12:N0} bytes" -f $_.Name, $_.Length) }
} else {
    Write-Host ("  NOT FOUND: {0}" -f $MoviesDir) -ForegroundColor Yellow
    foreach ($alt in 'D:\Hedz\Movies', 'D:\Movie', 'D:\Movies') {
        if (Test-Path $alt) { Write-Host ("  found instead: {0}" -f $alt); Get-ChildItem $alt -File | ForEach-Object { Write-Host ("     " + $_.Name) } }
    }
}

Write-Host ''
Write-Host '=== 2. AVI headers (fourcc tells us the codec) ===' -ForegroundColor Cyan
if (Test-Path $MoviesDir) {
    foreach ($f in (Get-ChildItem $MoviesDir -Filter *.avi -File | Sort-Object Name)) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        $riff = FourCC4 $b 0
        $form = FourCC4 $b 8
        Write-Host ("  --- {0}  ({1:N0} bytes) ---" -f $f.Name, $f.Length) -ForegroundColor Yellow
        Write-Host ("      container : '{0}' form '{1}'" -f $riff, $form)

        # find the video stream header: 'strh' then fccType 'vids' then fccHandler
        $handler = $null; $scale = $null
        for ($i = 0; $i -lt [Math]::Min($b.Length - 32, 600000); $i++) {
            if ($b[$i] -eq 0x73 -and $b[$i + 1] -eq 0x74 -and $b[$i + 2] -eq 0x72 -and $b[$i + 3] -eq 0x68) {  # 'strh'
                if ((FourCC4 $b ($i + 8)) -eq 'vids') {
                    $handler = FourCC4 $b ($i + 12)
                    $scale   = [BitConverter]::ToUInt32($b, $i + 36)
                    break
                }
            }
        }
        if ($handler) {
            Write-Host ("      video 4CC : '{0}'   (scale={1})" -f $handler, $scale) -ForegroundColor Green
            $known = @{
                'XVID' = 'Xvid MPEG-4'; 'DIVX' = 'DivX (legacy)'; 'DX50' = 'DivX 5'; 'MJPG' = 'Motion JPEG';
                'IV32' = 'Intel Indeo 3.2 (legacy, absent on Win11)'; 'IV41' = 'Indeo 4'; 'IV50' = 'Indeo 5 (legacy)';
                'CVID' = 'Cinepak (legacy)'; 'MRLE' = 'Microsoft RLE'; 'MSVC' = 'MS Video 1'; 'CRAM' = 'MS Video 1';
                'MP42' = 'MPEG-4 v2'; 'MP43' = 'MS MPEG-4 v3'; 'WMV1' = 'Windows Media 7'; 'WMV2' = 'Windows Media 8';
                'DIB ' = 'uncompressed RGB'; 'tpk ' = '?'; 'TRUE' = 'TruePlay?'; 'FPS1' = 'Fraps'
            }
            if ($known.ContainsKey($handler)) { Write-Host ("      meaning   : {0}" -f $known[$handler]) }
            else { Write-Host ("      meaning   : (not a well-known fourcc - possibly proprietary/DRM)") -ForegroundColor Yellow }
        } else {
            Write-Host '      video 4CC : NOT FOUND - not a standard AVI video stream header' -ForegroundColor Yellow
        }

        # TruePlay / protection markers
        $s = [Text.Encoding]::GetEncoding(28591).GetString($b)
        $mk = New-Object System.Collections.Generic.List[string]
        foreach ($m in 'TruePlay', 'TRUEPLAY', 'trueplay', 'Protected', 'DRM', 'WMA', 'license', 'indigo') {
            if ($s.IndexOf($m) -ge 0) { $mk.Add($m) }
        }
        if ($mk.Count) { Write-Host ("      markers   : {0}" -f ($mk -join ', ')) -ForegroundColor Yellow }

        Write-Host '      first 64 bytes:'
        $hex = ($b[0..63] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        $asc = -join ($b[0..63] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
        Write-Host ("        {0}" -f $hex)
        Write-Host ("        {0}" -f $asc)
    }
}

Write-Host ''
Write-Host '=== 3. TruePlay.dll (the movie/decode module) ===' -ForegroundColor Cyan
$tpPaths = @((Join-Path $GameDir 'TruePlay.dll'), 'D:\Hedz\TruePlay.dll') | Where-Object { Test-Path $_ }
foreach ($tp in $tpPaths) {
    $i = Get-Item $tp
    $b = [IO.File]::ReadAllBytes($tp)
    Write-Host ("  {0}  ({1:N0} bytes)" -f $tp, $i.Length) -ForegroundColor Yellow
    try {
        $vi = $i.VersionInfo
        foreach ($f in 'CompanyName', 'ProductName', 'FileDescription', 'FileVersion', 'OriginalFilename') {
            if ($vi.$f) { Write-Host ("      {0,-16}: {1}" -f $f, $vi.$f) }
        }
    } catch {}
    # imports
    $s = [Text.Encoding]::GetEncoding(28591).GetString($b)
    $dlls = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($s, '[A-Za-z0-9_\-]{2,32}\.dll')) {
        $n = $m.Value.ToLower()
        if ($dlls -notcontains $n) { $dlls.Add($n) }
    }
    Write-Host ("      dll refs        : {0}" -f (($dlls | Select-Object -First 18) -join ', '))
    $apis = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($s, '(?i)\b(ICOpen|ICSendMessage|ICClose|DrawDib\w*|GetSystemInfo|IsProcessorFeaturePresent|CPUID|QueryPerformanceCounter|timeGetTime|Movie\w*|TPlay\w*|Decode\w*)\b')) {
        if ($apis -notcontains $m.Value) { $apis.Add($m.Value) }
    }
    if ($apis.Count) { Write-Host ("      api hints       : {0}" -f (($apis | Select-Object -First 20) -join ', ')) }
}

Write-Host ''
Write-Host '=== 4. can movies be skipped? (strings + registry) ===' -ForegroundColor Cyan
Write-Host '  Hedz.exe movie-related literals:'
$exe = Join-Path $GameDir 'Hedz.exe'
if (Test-Path $exe) {
    $b = [IO.File]::ReadAllBytes($exe)
    $sb = New-Object System.Text.StringBuilder
    $strs = New-Object System.Collections.Generic.List[string]
    foreach ($x in $b) {
        if ($x -ge 32 -and $x -lt 127) { [void]$sb.Append([char]$x) }
        else { if ($sb.Length -ge 5) { $strs.Add($sb.ToString()) }; [void]$sb.Clear() }
    }
    $strs | Where-Object { $_ -match '(?i)movie|trueplay|\.avi|intro|skip|out-tro|tween-tro' } |
        Select-Object -Unique | ForEach-Object { Write-Host ('    ' + $_) }
}
Write-Host '  registry values under Vis Interactive\Hedz (any movie/play control):'
$k = 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if (Test-Path $k) {
    (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
        ForEach-Object { Write-Host ("    {0} = {1}" -f $_.Name, $_.Value) }
}
