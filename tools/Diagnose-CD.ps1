#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose-CD.ps1 - Find out why HEDZ says "insert the CD".

.DESCRIPTION
    Read-only diagnosis of the live environment:

      1. Optical/virtual CD drives and their volume labels (does the disc
         look mounted RIGHT NOW, and on which letter?)
      2. The game installation folder (explicit path or auto-discovered)
         and which files are present - including whether winmm.dll AND
         winmm_real.dll are both deployed.
      3. Settings files. NOTE: Hedz.exe never reads an INI (0 occurrences of
         ".ini" in the binary, no GetPrivateProfile* imports) - its settings
         live in the registry plus HardHedz.set. This section checks those.
      4. Registry under BOTH the 64-bit and 32-bit (WOW6432Node) views for
         the VIS Interactive keys, the InstallShield uninstall key, and
         HKCU equivalents - a 32-bit game reads the 32-bit view even when
         a 64-bit reg.exe import landed in the 64-bit view.
      5. Strings inside Hedz.exe that reveal how it locates the CD
         (registry key names, file probes, drive scans).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnose-CD.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnose-CD.ps1 -InstallDir "D:\Games\HEDZ"
#>
[CmdletBinding()]
param(
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Continue'

function Section { param($t) Write-Host ''; Write-Host ("=== " + $t + " ===") -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. drives
Section '1. Optical / virtual drives'
$cds = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 5 }
if (-not $cds) { Write-Host '  NO DRIVE WITH DriveType=5 (CD-ROM) FOUND -> nothing is mounted right now.' -ForegroundColor Red }
foreach ($d in $cds) {
    Write-Host ("  {0}  label='{1}'  fs={2}  size={3:N0}" -f $d.DeviceID, $d.VolumeName, $d.FileSystem, $d.Size)
}
$phys = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue
foreach ($p in $phys) { Write-Host ("  device {0} -> {1}  MediaLoaded={2}  Volume='{3}'" -f $p.Name, $p.Drive, $p.MediaLoaded, $p.VolumeName) }

# ------------------------------------------------------------ 2. install dir
Section '2. Game installation folder'
$candidates = @()
if ($InstallDir) { $candidates += $InstallDir }
$candidates += 'C:\GAMES\HEDZ', 'C:\Games\HEDZ', 'C:\Program Files (x86)\HEDZ', 'C:\Program Files\HEDZ',
               'C:\Program Files (x86)\Hasbro Interactive\HEDZ', 'C:\Program Files\Hasbro Interactive\HEDZ',
               'C:\Program Files (x86)\VIS Interactive\HEDZ', 'C:\HEDZ', 'C:\hedz-cd-root'
$found = @()
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'Hedz.exe')) { $found += $c }
}
if ($found.Count -eq 0) {
    Write-Host '  Not in common locations - scanning C:\ and D:\ (depth 3)...' -ForegroundColor Yellow
    foreach ($root in 'C:\', 'D:\') {
        Get-ChildItem $root -Filter 'Hedz.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue -Force |
            ForEach-Object { $found += $_.DirectoryName }
    }
}
$found = $found | Select-Object -Unique
if (-not $found) {
    Write-Host '  NO INSTALL FOUND anywhere scanned.' -ForegroundColor Red
} else {
    foreach ($f in $found) { Write-Host ("  install found: {0}" -f $f) -ForegroundColor Green }
}
$game = $null
if ($found) {
    # prefer the one that actually has the deployed proxy, else the first
    $game = ($found | Where-Object { Test-Path (Join-Path $_ 'winmm.dll') } | Select-Object -First 1)
    if (-not $game) { $game = $found[0] }
    Write-Host ("  using: {0}" -f $game)
}

if ($game) {
    Write-Host ''
    Write-Host '  deployed-file check:'
    foreach ($n in 'Hedz.exe','hedz.hdz','SoundFX.dat','MSS32.DLL','MSS16.DLL','TruePlay.dll','winmm.dll','winmm_real.dll','HardHedz.set') {
        $p = Join-Path $game $n
        if (Test-Path $p) {
            $i = Get-Item $p
            Write-Host ("    [ok]   {0,-16} {1,10:N0} bytes  {2}" -f $n, $i.Length, $i.LastWriteTime)
        } else {
            Write-Host ("    [MISS] {0}" -f $n) -ForegroundColor Yellow
        }
    }
    foreach ($sub in 'Music','Movies','MapFiles') {
        $p = Join-Path $game $sub
        if (Test-Path $p) { Write-Host ("    dir present: {0}" -f $sub) } else { Write-Host ("    dir absent : {0}" -f $sub) }
    }
    # proxy identity: does it match what we built?
    $mine = Join-Path $PSScriptRoot 'cdstub\build\winmm.dll'
    $theirs = Join-Path $game 'winmm.dll'
    if ((Test-Path $theirs) -and (Test-Path $mine)) {
        $same = (Get-FileHash $theirs).Hash -eq (Get-FileHash $mine).Hash
        Write-Host ("  winmm.dll matches the built stub: {0}" -f $same)
    }

    Write-Host ''
    Write-Host '  settings files (the game reads NO ini - registry + HardHedz.set only):'
    foreach ($n in 'HardHedz.set', 'hedz.ini') {
        $p = Join-Path $game $n
        if (Test-Path $p) {
            Write-Host ("    --- {0} ---" -f $n)
            Get-Content $p -TotalCount 40 | ForEach-Object { Write-Host ("      " + $_) }
        }
    }
    if (Test-Path (Join-Path $game 'hedz.ini')) {
        Write-Host '    [warn] an hedz.ini exists here but Hedz.exe never reads it - harmless, but not a fix.' -ForegroundColor Yellow
    }
    Write-Host '    (no INI is needed: Hedz.exe contains zero ".ini" strings and imports no' -ForegroundColor DarkGray
    Write-Host '     GetPrivateProfile*/WritePrivateProfile* APIs. CD letter comes from the' -ForegroundColor DarkGray
    Write-Host '     registry value InstalledFromDrive, which MUST include the colon, e.g. "D:".)' -ForegroundColor DarkGray
}

# --------------------------------------------------------------- 4. registry
Section '4. Registry (both views - 32-bit games read the WOW6432Node view)'
$regPaths = @(
    'SOFTWARE\VIS Interactive\HEDZ',
    'SOFTWARE\WOW6432Node\VIS Interactive\HEDZ',
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5BAA97BC-718C-11D2-84B1-006097616E32}',
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{5BAA97BC-718C-11D2-84B1-006097616E32}'
)
$views = @{
    'LM-64' = @('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    'LM-32' = @('LocalMachine', [Microsoft.Win32.RegistryView]::Registry32)
    'CU-64' = @('CurrentUser',  [Microsoft.Win32.RegistryView]::Registry64)
    'CU-32' = @('CurrentUser',  [Microsoft.Win32.RegistryView]::Registry32)
}
foreach ($vname in 'LM-64','LM-32','CU-64','CU-32') {
    $hive = $views[$vname][0]; $view = $views[$vname][1]
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
    foreach ($rp in $regPaths) {
        $sub = $base.OpenSubKey($rp)
        if ($sub) {
            $hiveTag = if ($hive -eq 'LocalMachine') { 'HKLM' } else { 'HKCU' }
            Write-Host ("  [{0}] {1}\{2}" -f $vname, $hiveTag, $rp) -ForegroundColor Green
            foreach ($n in $sub.GetValueNames()) {
                Write-Host ("        {0} = {1}" -f $n, $sub.GetValue($n))
            }
            $sub.Close()
        }
    }
    $base.Close()
}
Write-Host '  (silence for a hive/view means the key does not exist there)'

# ------------------------------------------------------- 5. strings evidence
Section '5. How Hedz.exe looks for the CD (string evidence)'
if (-not $game) { Write-Host '  skipped - no game folder found'; return }
$exe = Join-Path $game 'Hedz.exe'
$bytes = [IO.File]::ReadAllBytes($exe)
$lfanew = [BitConverter]::ToInt32($bytes, 0x3C)
$mach = [BitConverter]::ToUInt16($bytes, $lfanew + 4)
Write-Host ("  Hedz.exe machine=0x{0:X4} ({1})" -f $mach, ($(if ($mach -eq 0x14C) { '32-bit' } else { 'unexpected' })))

$latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
$pats = @(
    '[A-Za-z0-9_\\:\.\-]{4,}\.mus',
    '(?i)music',
    '(?i)hedz\.ini',
    '(?i)software\\[A-Za-z0-9 _\\]+',
    '(?i)cdaudio',
    '(?i)mci[A-Za-z]+',
    '(?i)insert',
    '(?i)cd-?rom',
    '(?i)volume',
    '(?i)getdrivetype',
    '(?i)[a-z]:\\\\(hedz|hedz)',
    '(?i)hedz\\\\',
    '(?i)\.set\b',
    '(?i)hasbro|vis interactive|visentertainment',
    '(?i)\\\\hedz\\'
)
$hits = @{}
foreach ($p in $pats) {
    foreach ($m in [regex]::Matches($latin, $p)) {
        $s = $m.Value.Trim()
        if ($s.Length -lt 4) { continue }
        if (-not $hits.ContainsKey($s)) { $hits[$s] = 0 }
        $hits[$s]++
    }
}
$keys = $hits.Keys | Sort-Object
Write-Host ("  {0} distinct interesting strings:" -f $keys.Count)
foreach ($k in $keys) {
    $v = $k.Replace("`r", ' ').Replace("`n", ' ')
    Write-Host ("    [{0,3}x] {1}" -f $hits[$k], $v)
}

Section 'Verdict hints'
Write-Host '  * If section 1 shows no DriveType=5 drive -> the disc simply is not mounted;'
Write-Host '    remount the image (WinCDEmu) before touching anything else.'
Write-Host '  * If the game looks up "SOFTWARE\VIS Interactive\HEDZ" and only the 64-bit'
Write-Host '    view exists -> import the key into WOW6432Node (32-bit view).'
Write-Host '  * If strings show a file/label probe (Music\*.mus, HEDZ label) and the mount is'
Write-Host '    correct, the winmm proxy is not the right layer - see TROUBLESHOOTING.md.'
