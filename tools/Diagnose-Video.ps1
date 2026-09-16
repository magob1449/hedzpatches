#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose-Video.ps1 - work out why H.E.D.Z. reaches a black screen and then
    exits, now that the CD check passes.

.DESCRIPTION
    Reported symptom: the disc check succeeds, the screen goes black, and the
    game closes by itself (no crash dialog). That points at display/device
    initialisation rather than the CD, so this collects:

      1. identity of every ddraw.dll / ddraw.ini / DDrawCompat.ini /
         dgVoodoo.conf in the game folder (a wrong or misconfigured wrapper
         produces exactly this symptom)
      2. AppCompatFlags entries for Hedz.exe, the game's own ResMode /
         FullScreen settings, and the display adapters present
      3. the game's EXIT CODE from a real launch - 0 means it deliberately
         bailed out of an init check, anything else points at a fault
      4. recent Application / WER log entries mentioning Hedz

    The game window will appear briefly and is closed automatically.

.PARAMETER Launch
    Actually launch the game to capture its exit code (default on).

.PARAMETER RunSeconds
    How long to wait for the game to exit on its own before killing it.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$SkipLaunch,
    [int]$RunSeconds = 15
)

$ErrorActionPreference = 'Continue'
$game = Split-Path $GameExe -Parent

function Section($t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. wrapper
Section '1. DirectDraw wrapper stack in the game folder'
foreach ($n in 'ddraw.dll', 'ddraw.ini', 'DDRAW.ini', 'DDrawCompat.ini', 'DDrawCompat', 'dgVoodoo.conf',
               'dgVoodoo.dll', 'D3D8.dll', 'D3D9.dll', 'd3dimm.dll', 'DCIMAN32.dll',
               'WineD3DForWindows.dll', 'libwine.dll', 'wined3d.dll') {
    $p = Join-Path $game $n
    if (-not (Test-Path $p)) { continue }
    $i = Get-Item $p
    $vi = $null
    try { $vi = $i.VersionInfo } catch {}
    Write-Host ("  [present] {0,-22} {1,10:N0} bytes" -f $n, $i.Length) -ForegroundColor Green
    if ($vi) {
        foreach ($f in 'CompanyName', 'ProductName', 'FileDescription', 'FileVersion', 'ProductVersion', 'OriginalFilename') {
            $v = $vi.$f
            if ($v) { Write-Host ("              {0,-16} {1}" -f $f, $v) }
        }
    }
}
if (-not (Test-Path (Join-Path $game 'ddraw.dll'))) {
    Write-Host '  NO ddraw.dll in the game folder - the system DirectDraw will be used,' -ForegroundColor Yellow
    Write-Host '  which cannot do paletted 8-bit modes on Win11 (black screen / exit).' -ForegroundColor Yellow
}

Section '1b. wrapper config contents'
foreach ($n in 'ddraw.ini', 'DDRAW.ini', 'DDrawCompat.ini', 'dgVoodoo.conf') {
    $p = Join-Path $game $n
    if (-not (Test-Path $p)) { continue }
    Write-Host ("  --- {0} ---" -f $n) -ForegroundColor Yellow
    Get-Content $p -TotalCount 80 | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host ('      ' + $_) }
}

# ------------------------------------------------- 2. registry / display state
Section '2. game settings + compatibility flags'
foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz', 'HKLM:\SOFTWARE\Vis Interactive\Hedz') {
    if (-not (Test-Path $k)) { continue }
    Write-Host ("  {0}" -f $k)
    $props = (Get-ItemProperty $k)
    foreach ($f in 'FullScreen', 'ResMode', 'ClipPlane', 'Models', 'Lighting', 'MusicLevel', 'SoundLevel', 'InstalledFromDrive') {
        if ($props.PSObject.Properties.Name -contains $f) { Write-Host ("      {0,-10} = {1}" -f $f, $props.$f) }
    }
}
Write-Host '  AppCompatFlags Layers entries for Hedz:'
$found = $false
foreach ($k in 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
               'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') {
    if (-not (Test-Path $k)) { continue }
    (Get-ItemProperty $k).PSObject.Properties |
        Where-Object { $_.Name -match '(?i)hedz' } |
        ForEach-Object { $found = $true; Write-Host ("      {0}  =>  {1}" -f $_.Name, $_.Value) }
}
if (-not $found) { Write-Host '      (none - no compatibility layer set)' }

Write-Host '  display adapters:'
Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("      {0}  driver {1}  ({2})" -f $_.Name, $_.DriverVersion, $_.VideoModeDescription) }

# --------------------------------------------------------------- 3. exit code
$exitCode = $null
if ($SkipLaunch) {
    Section '3. launch test SKIPPED (-SkipLaunch)'
} else {
    Section '3. launch test - capturing the exit code'
    if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $GameExe -WorkingDirectory $game -PassThru
    Write-Host ("  started pid {0}; waiting up to {1}s for it to exit on its own..." -f $p.Id, $RunSeconds)
    $exited = $p.WaitForExit($RunSeconds * 1000)
    $sw.Stop()
    if ($exited) {
        $exitCode = $p.ExitCode
        Write-Host ("  EXITED BY ITSELF after {0:N1}s with code {1}" -f $sw.Elapsed.TotalSeconds, $exitCode) -ForegroundColor Yellow
        if ($exitCode -eq 0) {
            Write-Host '  code 0 => a deliberate bail-out from an init check, not a fault.' -ForegroundColor Yellow
            Write-Host '  prime suspects: SetDisplayMode / CreateDevice failed, movie (TruePlay) failed,' -ForegroundColor Yellow
            Write-Host '  or the wrapper refused the paletted mode.' -ForegroundColor Yellow
        } else {
            Write-Host ("  code {0} (0x{0:X8}) => looks like a fault/termination, check section 4." -f $exitCode) -ForegroundColor Yellow
        }
    } else {
        Write-Host ("  still running after {0}s - it did NOT self-exit this time." -f $RunSeconds) -ForegroundColor Green
        Write-Host '  (a black screen with the process alive is a rendering problem, not an exit path)'
        Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    }
}

# ------------------------------------------------------------------ 4. logs
Section '4. Application / WER log entries mentioning Hedz (last 20)'
$since = (Get-Date).AddDays(-3)
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match '(?i)hedz' } | Select-Object -First 20
if ($events) {
    foreach ($e in $events) {
        Write-Host ("  --- {0}  [{1}] id={2} {3}" -f $e.TimeCreated, $e.LevelDisplayName, $e.Id, $e.ProviderName) -ForegroundColor Yellow
        ($e.Message -split "`r?`n") | Where-Object { $_ -match '\S' } | Select-Object -First 12 |
            ForEach-Object { Write-Host ('      ' + $_.Trim()) }
    }
} else {
    Write-Host '  (no Application-log entries mentioning Hedz in the last 3 days)'
    Write-Host '  => no fault was recorded: consistent with a clean exit(0) bail-out.'
}

Section '5. summary'
if ($exitCode -eq 0) {
    Write-Host 'VERDICT: the game intentionally aborted during initialisation.' -ForegroundColor Yellow
} elseif ($exitCode -ne $null) {
    Write-Host ("VERDICT: process terminated with code {0}." -f $exitCode) -ForegroundColor Yellow
} else {
    Write-Host 'VERDICT: game stayed alive - look at rendering, not the exit path.'
}
