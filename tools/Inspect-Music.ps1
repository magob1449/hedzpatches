<#
.SYNOPSIS
    Inspect-Music.ps1 - what music does HEDZ actually expect, and what is on the disc?

.DESCRIPTION
    The CD path is proven good: all seven .mus tracks are present, the game opens
    them one by one (<drive>:\Hedz\Music\<n>.mus) and its hard-coded expected byte
    sizes match, so it gets past its own protection check. Sound effects work, so
    DirectSound output is fine.

    Therefore the failure is inside the music subsystem. This read-only pass lists
    the complete Music folder (including the .amb files the earlier notes only
    mentioned in passing) and pulls every music-related string out of Hedz.exe, so
    the filename scheme and format the game builds can be compared with what is
    really on the disc.

    Read-only.
#>
$ErrorActionPreference='Continue'

Write-Host '=== complete CD Music folder ==='
$cd=$null
$k='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if(Test-Path $k){ $cd=(Get-ItemProperty $k -Name InstalledFromDrive -ErrorAction SilentlyContinue).InstalledFromDrive }
if($cd){ $cd=$cd.ToString().TrimEnd('\') }
$mus=if($cd){ Join-Path $cd 'Hedz\Music' } else { 'D:\Hedz\Music' }
if(Test-Path $mus){
    Get-ChildItem $mus | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-16} {1,12:N0}   {2}" -f $_.Name,$_.Length,$_.LastWriteTime)
    }
} else { Write-Host ("  {0} not reachable" -f $mus) }

Write-Host ''
Write-Host '=== local install: is there any Music/audio data beside the exe? ==='
foreach($d in 'C:\GAMES\HEDZ','C:\GAMES\HEDZ\Music'){
    if(Test-Path $d){
        $files=Get-ChildItem $d -File -ErrorAction SilentlyContinue
        Write-Host ("  {0}: {1} files" -f $d,$files.Count)
        $files | Where-Object { $_.Name -match '(?i)\.(mus|amb|wav|dat|mp3|adp)$' } |
            ForEach-Object { Write-Host ("     {0,-24} {1,12:N0}" -f $_.Name,$_.Length) }
    }
}

Write-Host ''
Write-Host '=== music-related strings in Hedz.exe ==='
$b=[IO.File]::ReadAllBytes('C:\GAMES\HEDZ\Hedz.exe')
$sb=New-Object System.Text.StringBuilder
$strs=New-Object System.Collections.Generic.List[object]
for($i=0;$i -lt $b.Length;$i++){
    $c=$b[$i]
    if($c -ge 32 -and $c -lt 127){ [void]$sb.Append([char]$c) } else {
        if($sb.Length -ge 3){ $strs.Add([pscustomobject]@{Off=($i-$sb.Length);S=$sb.ToString()}) }
        [void]$sb.Clear() }
}
$re='(?i)(\.mus|\.amb|\.wav|miles|mss32|ail_|digital ?audio|red ?book|cd ?audio|mci|audiocd|AUDIO INFO|MUSIC|streamer|playlist|ambient|\.adp|adpcm|dsi|directmusic)'
$strs | Where-Object { $_.S -match $re -and ($_.S -match '\s' -or $_.S.Length -gt 6) } |
    ForEach-Object { Write-Host ("  {0:X6}  {1}" -f $_.Off,$_.S) }

Write-Host ''
Write-Host '=== imported audio APIs (from the import table) ==='
$strs | Where-Object { $_.S -match '^(mciSendStringA|mciSendCommandA|mciGetDeviceID|auxGetVolume|waveOutOpen|waveOutWrite|waveOutGetPosition|DirectSoundCreate|DirectSoundEnumerateA|DllGetClassObject|AIL_|_AIL_)' } |
    ForEach-Object { Write-Host ("  {0:X6}  {1}" -f $_.Off,$_.S) }
