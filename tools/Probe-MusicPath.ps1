<#
.SYNOPSIS
    Probe-MusicPath.ps1 - read-only survey of the disc music layout, the mount, and
    the registry values the game reads.

.DESCRIPTION
    New evidence from the operator: on the original Windows 98 machine the .mus files
    were NEVER copied to the local drive and the game played them fine, and on THIS
    machine the title-screen ambient music already plays - only the level (.mus)
    music is silent.

    That splits the problem. If title/ambient audio works, then Miles AIL, the audio
    output path and (probably) CD path resolution all work, and something specific to
    the level-music stream is failing. This probe gathers the facts needed to tell
    which:

      * the complete disc layout (root, \Music, \Hedz, \Hedz\Music) with exact sizes,
        because the music code's own path literal in Hedz.exe is "\Music\" while the
        anti-piracy check builds "\Hedz\Music\"
      * what D: actually is and how it is mounted (physical drive vs virtual image,
        and whether the image is data-only .ISO or a track-aware .BIN/.CUE)
      * every value under the game's registry key, both registry views
      * the full install folder, including any Music\ or cache artefacts

    Read-only. Nothing is started, mounted or modified.
#>
$ErrorActionPreference='Continue'

function Head($s){ Write-Host ''; Write-Host ("=== $s ===") -ForegroundColor Cyan }

Head 'drive D: - what is it, and how is it mounted?'
try{
    Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'" |
        Select-Object DeviceID,DriveType,FileSystem,VolumeName,Size,FreeSpace |
        Format-List | Out-String -Width 200 | Write-Host
}catch{ Write-Host ("  Win32_LogicalDisk: {0}" -f $_.Exception.Message) }
try{
    Get-CimInstance Win32_CDROMDrive | Select-Object Drive,Caption,DeviceID,MediaType,PNPDeviceID |
        Format-List | Out-String -Width 200 | Write-Host
}catch{ Write-Host ("  Win32_CDROMDrive: {0}" -f $_.Exception.Message) }
try{
    Get-Volume -DriveLetter D -ErrorAction Stop |
        Select-Object DriveLetter,FileSystemLabel,FileSystem,DriveType,Size |
        Format-List | Out-String -Width 200 | Write-Host
}catch{ Write-Host ("  Get-Volume: {0}" -f $_.Exception.Message) }

Head 'any disc image / cue sheet visible? (tells us if audio tracks exist)'
$cands=@()
foreach($root in 'C:\Images','C:\Games','D:\','E:\',"$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents"){
    if(-not (Test-Path $root)){ continue }
    try{
        $cands += Get-ChildItem $root -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -match '(?i)\.(iso|bin|cue|mds|mdf|nrg|ccd|7z|rar|zip)$' -and $_.Length -gt 10MB }
    }catch{}
}
$cands = $cands | Sort-Object FullName -Unique
if($cands){
    foreach($f in $cands){
        Write-Host ("  {0,-70} {1,14:N0}  {2}" -f $f.FullName,$f.Length,$f.LastWriteTime)
    }
    $cues=$cands | Where-Object { $_.Extension -match '(?i)\.cue$' }
    if($cues){
        Write-Host ''
        Write-Host '  --- cue sheet contents (TRACK list proves whether audio tracks are in the image) ---'
        foreach($c in $cues){ Write-Host ("  [{0}]" -f $c.FullName); Get-Content $c.FullName | ForEach-Object { Write-Host ("    {0}" -f $_) } }
    } else {
        Write-Host ''
        Write-Host '  NOTE: no .cue/.bin found - if the mounted image is a plain .iso, any' -ForegroundColor Yellow
        Write-Host '        Red Book audio tracks on the original disc are NOT in the image.' -ForegroundColor Yellow
    }
} else { Write-Host '  (no image files found within depth 3 of C:\Users, C:\, D:\, E:\)' }

Head 'registry: HKLM\SOFTWARE\Vis Interactive\Hedz (64-bit view)'
foreach($p in 'HKLM:\SOFTWARE\Vis Interactive\Hedz','HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'){
    Write-Host ("  [{0}]" -f $p)
    if(Test-Path $p){
        $it=Get-ItemProperty $p
        $it.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Sort-Object Name |
            ForEach-Object { Write-Host ("    {0,-28} = {1}" -f $_.Name,$_.Value) }
    } else { Write-Host '    (key absent)' }
}

Head 'disc layout - root of D:'
if(Test-Path 'D:\'){
    Get-ChildItem 'D:\' | Sort-Object Name |
        ForEach-Object { Write-Host ("  {0,-34} {1,14:N0}  {2}" -f $_.Name,$(if($_.PSIsContainer){''}else{$_.Length}),$(if($_.PSIsContainer){'<DIR>'}else{''})) }
} else { Write-Host '  D:\ not reachable - is the image mounted?' }

foreach($sub in 'Music','Hedz','Hedz\Music','Movies'){
    Head ("disc layout - D:\{0}" -f $sub)
    $p=Join-Path 'D:\' $sub
    if(Test-Path $p){
        Get-ChildItem $p | Sort-Object Name |
            ForEach-Object { Write-Host ("  {0,-34} {1,14:N0}" -f $_.Name,$(if($_.PSIsContainer){-0}else{$_.Length})) }
    } else { Write-Host ("  {0}  ->  ABSENT" -f $p) -ForegroundColor Yellow }
}

Head 'install folder - complete'
$g='C:\GAMES\HEDZ'
if(Test-Path $g){
    Get-ChildItem $g | Sort-Object Name |
        ForEach-Object { Write-Host ("  {0,-34} {1,14:N0}  {2}" -f $_.Name,$(if($_.PSIsContainer){''}else{$_.Length}),$(if($_.PSIsContainer){'<DIR>'}else{''})) }
    if(Test-Path (Join-Path $g 'Music')){ Write-Host '  -> a local Music\ folder EXISTS (should not, per the original full install)' -ForegroundColor Yellow }
} else { Write-Host '  C:\GAMES\HEDZ not found' }
