#Requires -Version 5.1
<#
.SYNOPSIS
    Get-HedzCrashLog.ps1 - Post-crash triage for H.E.D.Z.

.DESCRIPTION
    Pulls the newest Application-log crash events (Event ID 1000 application
    error, 1001 Windows Error Reporting) that mention Hedz.exe or its known
    support DLLs, prints faulting module / exception code / offset, locates
    the WER report folder, and matches the result against the crash taxonomy
    in README.md (Task 1).

    Run right after reproducing a crash.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-HedzCrashLog.ps1 -Last 5
#>
[CmdletBinding()]
param(
    # How many recent events to inspect.
    [int]$Last = 5
)

$ErrorActionPreference = 'SilentlyContinue'

$watchNames = @('Hedz.exe', 'TruePlay.dll', 'MSS32.DLL', 'MSS16.DLL', 'ddraw.dll', 'dxwnd.dll', 'dxwddraw.dll')
$since = (Get-Date).AddDays(-14)

Write-Host '=== HEDZ crash triage ===' -ForegroundColor Cyan
Write-Host ('Window: last {0} events, last 14 days' -f $Last)
Write-Host ''

# --- Application error events (ID 1000) ---
$events = Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    Id        = 1000, 1001
    StartTime = $since
} -MaxEvents 200 | Where-Object {
    $msg = $_.Message
    ($watchNames | Where-Object { $msg -match [regex]::Escape($_) }).Count -gt 0
} | Select-Object -First $Last

if (-not $events) {
    Write-Host 'No matching crash events found in the last 14 days.' -ForegroundColor Green
    Write-Host '(If the crash just happened, make sure it was Hedz.exe and re-run.)'
    return
}

foreach ($ev in $events) {
    Write-Host ('-' * 70)
    Write-Host ('Event {0}  {1}  [{2}]' -f $ev.Id, $ev.TimeCreated, $ev.ProviderName) -ForegroundColor Yellow

    $msg = $ev.Message
    # Event 1000 layout: "Faulting application name: X, version..., Faulting module name: Y, ..."
    if ($msg -match 'Faulting application name:\s*([^,]+)') {
        Write-Host ('  App     : ' + $Matches[1])
    }
    if ($msg -match 'Faulting module name:\s*([^,]+),\s*version[^,]*,.*?Exception code:\s*(0x[0-9A-Fa-f]+)') {
        Write-Host ('  Module  : ' + $Matches[1]) -ForegroundColor Red
        Write-Host ('  Except. : ' + $Matches[2])
    }
    elseif ($msg -match 'Faulting module name:\s*([^,]+)') {
        Write-Host ('  Module  : ' + $Matches[1]) -ForegroundColor Red
    }
    if ($msg -match 'Faulting offset:\s*(0x[0-9A-Fa-f]+)') {
        Write-Host ('  Offset  : ' + $Matches[1])
    }
    if ($msg -match 'Faulting application path:\s*(\S+)') {
        Write-Host ('  Path    : ' + $Matches[1])
    }

    # Taxonomy match
    $mod = if ($msg -match 'Faulting module name:\s*([^,]+)') { $Matches[1].ToLower() } else { '' }
    $hint =
        if     ($mod -match 'trueplay')     { 'C2 (movie codec privileged instruction) -> see README Task 1 "Movies / TruePlay.dll"'
        } elseif ($mod -match 'mss32|mss16'){ 'Miles Sound System fault -> verify DLLs are the unmodified CD copies (Task 2, Layer B)'
        } elseif ($mod -match 'ddraw')      { 'C1 (surface lock/unlock or flip timing) or C4/C5 -> ensure pal-ddraw/DDrawCompat is deployed and DxWnd flags active'
        } elseif ($mod -match 'hedz\.exe')  { 'C3 (CD access) if during level load / music start -> verify the image is mounted and InstalledFromDrive is "<LETTER>:" WITH the colon (Task 2)'
        } else                              { 'Unknown module - attach full WER report before deeper analysis' }
    Write-Host ('  Match   : ' + $hint) -ForegroundColor Cyan
}

Write-Host ('-' * 70)
Write-Host ''

# --- WER report folders ---
Write-Host 'WER report folders (newest first):'
$wer = Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -Directory -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match 'hedz' } |
       Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($wer) {
    foreach ($w in $wer) {
        Write-Host ('  ' + $w.FullName + '  (' + $w.LastWriteTime + ')')
    }
    Write-Host ''
    Write-Host 'Open Report.wer inside the newest folder for the full stack.'
} else {
    Write-Host '  (none found)'
}
