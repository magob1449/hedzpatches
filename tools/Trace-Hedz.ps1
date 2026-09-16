#Requires -Version 5.1
<#
.SYNOPSIS
    Trace-Hedz.ps1 - record what Hedz.exe really does during the CD check.

.DESCRIPTION
    The game rejected the mounted CD even though the drive, registry value and
    file sizes all look correct. Static analysis found the exact checks:

        * CreateFileA + GetFileSize on CD files
        * GetDriveTypeA(drive)
        * GetDiskFreeSpaceExA(drive)      -> "CD is the wrong size"
        * CreateFileA("<cdroot>test")     -> "disc is writeable"
        * per-track size check on
              <drive>:\Hedz\Music\<n>.MUS  vs a hardcoded expected byte count
              (1.MUS must be 56952417, 2.MUS 38467297, ...)
                                        -> "%s missing" / "%s wrong size"

    This runs the game for a few seconds under Process Monitor and reports
    every registry and file operation, highlighting the ones that FAIL.
    The game window appears briefly and is closed automatically.

.NOTES
    Must run elevated (ProcMon loads a kernel filter driver).
#>
[CmdletBinding()]
param(
    [string]$GameExe   = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$GameSeconds  = 8,
    [string]$OutDir    = '',
    [switch]$KeepCsv
)

$ErrorActionPreference = 'Continue'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'trace' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$pm = @(
    "$env:USERPROFILE\Desktop\Procmon64.exe",
    'C:\Sysinternals\Procmon64.exe',
    'C:\Tools\Procmon64.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pm) { throw 'Procmon64.exe not found.' }
Write-Host ("ProcMon : {0}" -f $pm) -ForegroundColor Cyan

$pml = Join-Path $OutDir 'hedz.pml'
$csv = Join-Path $OutDir 'hedz.csv'
Remove-Item $pml, $csv -Force -ErrorAction SilentlyContinue

# stop any ProcMon already running so /BackingFile does not collide
Get-Process -Name Procmon64, Procmon -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 1

Write-Host '[1/4] starting capture...'
Start-Process -FilePath $pm -ArgumentList '/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', $pml
Start-Sleep -Seconds 4
if (-not (Get-Process -Name Procmon64, Procmon -ErrorAction SilentlyContinue)) {
    throw 'ProcMon did not start - run Procmon64.exe once manually and accept the EULA.'
}

Write-Host ('[2/4] launching game for {0}s...' -f $GameSeconds)
if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }
Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) | Out-Null
Start-Sleep -Seconds $GameSeconds
Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 1

Write-Host '[3/4] stopping capture...'
& $pm /Terminate | Out-Null
Start-Sleep -Seconds 3

Write-Host '[4/4] exporting CSV...'
& $pm /OpenLog $pml /SaveAs $csv /Quiet | Out-Null
Start-Sleep -Seconds 4
Get-Process -Name Procmon64, Procmon -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

if (-not (Test-Path $csv)) { throw "CSV not produced at $csv - open $pml in ProcMon manually and File>Save As CSV." }
Write-Host ("  CSV: {0:N0} bytes" -f (Get-Item $csv).Length)

# ---------------- analyse ----------------
Add-Type -AssemblyName Microsoft.VisualBasic
$parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($csv)
$parser.SetDelimiters(',')
$parser.HasFieldsEnclosedInQuotes = $true
$parser.TextFieldType = 'Delimited'

$header = $parser.ReadFields()
$iProc = [Array]::IndexOf($header, 'Process Name')
$iOp   = [Array]::IndexOf($header, 'Operation')
$iPath = [Array]::IndexOf($header, 'Path')
$iRes  = [Array]::IndexOf($header, 'Result')
Write-Host ("columns: proc={0} op={1} path={2} res={3}" -f $iProc, $iOp, $iPath, $iRes) -ForegroundColor DarkGray

$procOps  = New-Object System.Collections.Generic.List[object]
$regOps   = New-Object System.Collections.Generic.List[object]
$failOps  = New-Object System.Collections.Generic.List[string]
$musicOps = New-Object System.Collections.Generic.List[string]
$timeline = New-Object System.Collections.Generic.List[object]
$iDet     = [Array]::IndexOf($header, 'Detail')
$iTime    = [Array]::IndexOf($header, 'Time of Day')
$total = 0
while (-not $parser.EndOfData) {
    $f = $parser.ReadFields()
    $total++
    if ($f.Count -le [Math]::Max($iRes, $iPath)) { continue }
    if ($f[$iProc] -notmatch '(?i)^hedz(\.exe)?$') { continue }
    $op = $f[$iOp]; $path = $f[$iPath]; $res = $f[$iRes]
    $det = if ($iDet -ge 0 -and $f.Count -gt $iDet) { $f[$iDet] } else { '' }
    $tim = if ($iTime -ge 0 -and $f.Count -gt $iTime) { $f[$iTime] } else { '' }
    $t2 = $null
    try { $t2 = [datetime]::Parse($tim) } catch { }
    $procOps.Add([pscustomobject]@{ Op = $op; Path = $path; Res = $res })
    $timeline.Add([pscustomobject]@{ T = $tim; T2 = $t2; Op = $op; Path = $path; Res = $res; Det = $det })
    if ($op -like 'Reg*') { $regOps.Add([pscustomobject]@{ Op=$op; Path=$path; Res=$res }) }
    if ($res -notmatch '(?i)^(SUCCESS|REPARSEPOINT|OPLOCK|PENDING|FAST IO|END OF FILE|BUFFER OVERFLOW|NO MORE ENTRIES|NOT REPARSE POINT)$') {
        $failOps.Add(("{0,-16} {1}  ->  {2}" -f $op, $path, $res))
    }
    if ($path -match '(?i)music|\.mus|\.amb|test|\\\\Device') { $musicOps.Add(("{0,-16} {1}  ->  {2}" -f $op, $path, $res)) }
}
$parser.Close()
Write-Host ("scanned {0} events, {1} from Hedz.exe" -f $total, $procOps.Count) -ForegroundColor Cyan

$rep = Join-Path $OutDir 'report.txt'
$sb = New-Object System.Text.StringBuilder
function W($s) { Write-Host $s; [void]$sb.AppendLine($s) }

W ''
W '================= PROCESS EVENTS (start/exit + exit status) ================='
$pev = $timeline | Where-Object { $_.Op -like 'Process *' }
if ($pev.Count) { $pev | ForEach-Object { W ('  {0}  {1}  {2}  {3}' -f $_.T, $_.Op, $_.Path, $_.Det) } }
else { W '  (no process events captured)' }

W ''
W '================= POST-CD-CHECK ACTIVITY (everything after the disc check) ================='
$cdMark = $timeline | Where-Object { $_.Path -eq 'D:\Hedz\test' } | Select-Object -First 1
if ($cdMark -and $cdMark.T2) {
    $after = $timeline | Where-Object {
        $_.T2 -and $_.T2 -ge $cdMark.T2 -and
        $_.Op -notmatch '(?i)^(QueryOpen|QueryDirectory|CreateFileMapping)$' -and
        $_.Res -notmatch '(?i)FAST IO DISALLOWED|FILE LOCKED WITH ONLY READERS|NAME COLLISION'
    }
    $after | Select-Object -First 220 | ForEach-Object { W ('  {0}  {1,-18} {2}  ->  {3}' -f $_.T, $_.Op, $_.Path, $_.Res) }
    W ('  ... {0} ops after the CD check in total' -f $after.Count)

    # how long did it sit idle before exiting?
    $exitEv = $timeline | Where-Object { $_.Op -eq 'Process Exit' } | Select-Object -Last 1
    $lastOp = $after | Select-Object -Last 1
    if ($exitEv -and $exitEv.T2 -and $lastOp) {
        W ''
        W ('  last activity : {0}' -f $lastOp.T)
        W ('  process exit  : {0}' -f $exitEv.T)
        W ('  IDLE GAP before exit: {0:N1} s   <-- time spent doing nothing' -f ($exitEv.T2 - $lastOp.T2).TotalSeconds)
    }
} else {
    W '  (could not locate the CD-check marker D:\Hedz\test in the trace)'
}

W ''
W '================= TIMELINE: last 60 meaningful ops before it bailed ================='
$tl = $timeline | Where-Object {
    $_.Op -notmatch '(?i)^(QueryOpen|QueryDirectory|QueryStandardInformationFile|CreateFileMapping|CloseFile|ReadFile|IRP_MJ_)' -and
    $_.Res -notmatch '(?i)FAST IO DISALLOWED|FILE LOCKED WITH ONLY READERS|NAME COLLISION|BUFFER OVERFLOW'
}
$tl | Select-Object -Last 60 | ForEach-Object {
    W ('  {0}  {1,-14} {2}  ->  {3}' -f $_.T, $_.Op, $_.Path, $_.Res)
}

W ''
W '================= D: (CD) READS - shows how far into disc content it got ================='
$timeline | Where-Object { $_.Path -match '^D:' -and $_.Op -eq 'CreateFile' } | ForEach-Object {
    W ('  {0}  {1}  ->  {2}' -f $_.T, $_.Path, $_.Res)
}

W ''
W '================= FILE OPS THAT FAILED (Hedz.exe) ================='
if ($failOps.Count) { ($failOps | Select-Object -Unique | Sort-Object) | ForEach-Object { W ('  ' + $_) } }
else { W '  (none)' }

W ''
W '================= CD / MUSIC / TEST RELATED OPS ================='
if ($musicOps.Count) { ($musicOps | Select-Object -Unique) | ForEach-Object { W ('  ' + $_) } }
else { W '  (none)' }

W ''
W '================= REGISTRY OPS (Hedz.exe) ================='
($regOps | Select-Object -Unique | ForEach-Object { '  {0,-16} {1}  ->  {2}' -f $_.Op, $_.Path, $_.Res }) | ForEach-Object { W $_ }

[void]$sb.Insert(0, ("HEDZ Process Monitor report`nHedz.exe events scanned: {0}`n`n" -f $procOps.Count))
[IO.File]::WriteAllText($rep, $sb.ToString())
Write-Host ''
Write-Host ("report saved: {0}" -f $rep) -ForegroundColor Green

# The PML and CSV are large (hundreds of MB). Keep only on request.
if ($KeepCsv) {
    Write-Host ("CSV kept at {0} for follow-up greps." -f $csv) -ForegroundColor DarkGray
} else {
    foreach ($big in $pml, $csv) {
        if (Test-Path $big) { Remove-Item $big -Force -ErrorAction SilentlyContinue }
    }
    Write-Host 'Large trace files removed (re-run with -KeepCsv to retain them).' -ForegroundColor DarkGray
}
