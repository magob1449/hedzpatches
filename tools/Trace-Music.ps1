<#
.SYNOPSIS
    Trace-Music.ps1 - records exactly what the music subsystem does, in the front end
    (where music IS heard) and inside a level (where it is not).

.DESCRIPTION
    Facts already measured, none assumed:

      * The disc path is good: the game opens <drive>:\Hedz\Music\1..7.mus and its
        hard-coded expected byte sizes match, so the anti-piracy check passes.
      * Sound effects work, so MSS32.DLL and the DirectSound output path are fine.
      * Hedz.exe imports AIL_redbook_stop / AIL_redbook_close but NOT
        AIL_redbook_play, so level music is not Red Book CD audio. The streaming
        path (AIL_open_stream / AIL_start_stream) is the only way it can play.
      * In the FRONT END the game streams D:\Hedz\Music\F.MUS off the disc - captured,
        240 read operations - which is why the title music is audible.
      * Entering a level has never yet been captured, so the level-music attempt is
        still unmeasured. That is what this run is for.

    Design notes, learned the hard way:
      * The capture deliberately starts only once the front end is up (or once the
        front-end dialog disappears, which is the best local signal that a level is
        being entered). The game's startup enumerates thousands of DirectDraw driver
        keys and would bury the signal.
      * The capture stops EARLY if the game process exits, so quitting the game does
        not waste the run.
      * The report is produced by a streaming reader that first prunes the (very
        large) CSV down to the Hedz.exe lines. A previous version handed a 682 MB
        CSV to TextFieldParser and died before writing anything.

.NOTES
    Elevated (ProcMon drives its kernel filter driver). Writes tools\trace\music-report.txt,
    plus a pruned tools\trace\hedz-events.txt. Use -Detach to re-launch this script in
    its own visible window (so it can be started elevated and then left to run while
    you play).
#>
[CmdletBinding()]
param(
    [int]$Seconds   = 90,    # capture length once a level is believed to be running
    [int]$MenuWait  = 90,    # wait for the front end to appear
    [int]$LevelWait = 240,   # wait for the front-end dialog to disappear (level entry)
    [switch]$Direct,         # launch Hedz.exe directly instead of through DxWnd
    [switch]$Detach          # re-launch in a new visible window and return immediately
)

$ErrorActionPreference = 'Continue'

$kit  = $PSScriptRoot
$rt   = Join-Path $kit 'dxwnd\runtime'
$prof = Join-Path $kit 'dxwnd\HEDZ.dxw'
$game = 'C:\GAMES\HEDZ\Hedz.exe'
$gdir = Split-Path $game -Parent
$out  = Join-Path $kit 'trace'
if(-not (Test-Path $out)){ New-Item -ItemType Directory -Path $out -Force | Out-Null }

if($Detach){
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
              '-Seconds',$Seconds,'-MenuWait',$MenuWait,'-LevelWait',$LevelWait)
    if($Direct){ $argl += '-Direct' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -WorkingDirectory $kit | Out-Null
    Write-Host 'Trace re-launched in its own window - this one can close.'
    exit 0
}

function T { '{0:HH:mm:ss.fff}' -f (Get-Date) }
$phases = New-Object System.Collections.Generic.List[string]

# ---- window probing (reference types so mutations survive the callback) ----
if(-not ('HedzWin' -as [type])){
    Add-Type -Namespace '' -Name 'HedzWin' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int max);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int max);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
'@
}
function Get-HedzWindows {
    $proc = Get-Process -Name Hedz -ErrorAction SilentlyContinue
    if(-not $proc){ return @() }
    $pids = @($proc | ForEach-Object { $_.Id })
    $found = New-Object System.Collections.ArrayList
    $cb = [HedzWin+EnumProc]{
        param($h,$l)
        $pid2 = 0
        [void][HedzWin]::GetWindowThreadProcessId($h,[ref]$pid2)
        if($pids -contains $pid2){
            $c = New-Object System.Text.StringBuilder 256
            [void][HedzWin]::GetClassName($h,$c,256)
            $t = New-Object System.Text.StringBuilder 256
            [void][HedzWin]::GetWindowText($h,$t,256)
            [void]$found.Add([pscustomobject]@{Class=$c.ToString();Title=$t.ToString();Visible=[HedzWin]::IsWindowVisible($h)})
        }
        return $true
    }
    [void][HedzWin]::EnumWindows($cb,[IntPtr]::Zero)
    return $found
}

Write-Host '===============================================================' -ForegroundColor Yellow
Write-Host ' H.E.D.Z. level-music capture' -ForegroundColor Yellow
Write-Host '===============================================================' -ForegroundColor Yellow
Write-Host ' The game will start at 800x600. Click NEW GAME, pick a level,' -ForegroundColor Green
Write-Host ' and PLAY for about a minute. Leave this window alone.' -ForegroundColor Green
Write-Host ''

# ---- ProcMon ----
$pm = @(
    "$env:USERPROFILE\Desktop\Procmon64.exe",
    'C:\Sysinternals\Procmon64.exe',
    'C:\Tools\Procmon64.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not $pm){ throw 'Procmon64.exe not found.' }
Write-Host ("ProcMon : {0}" -f $pm) -ForegroundColor Cyan

# ---- one authoritative DirectDraw layer only ----
$pdd    = Join-Path $gdir 'DDRAW.dll'
$pddOff = Join-Path $gdir 'DDRAW.dll.pal-ddraw-disabled'
$restorePal = $false
if(Test-Path $pdd){
    if(Test-Path $pddOff){ Remove-Item $pddOff -Force }
    Move-Item $pdd $pddOff -Force
    $restorePal = $true
    Write-Host 'pal-ddraw retired (stacking it with DxWnd is proven to fault in ddraw.dll)' -ForegroundColor Yellow
}

$pml    = Join-Path $out 'music.pml'
$csv    = Join-Path $out 'music.csv'
$pruned = Join-Path $out 'hedz-events.txt'
Remove-Item $pml,$csv,$pruned -Force -ErrorAction SilentlyContinue
Get-Process -Name Procmon64,Procmon -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
Start-Sleep -Seconds 1

# ---- clean start ----
Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
$dxServer=$null
if(-not $Direct){
    if(-not (Test-Path (Join-Path $rt 'dxwnd.exe'))){ throw 'DxWnd not deployed - run tools\Install-DxWnd.ps1' }
    Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
    Start-Sleep -Milliseconds 700
    $dxServer = Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/T','/Q' -WorkingDirectory $rt -PassThru
    Start-Sleep -Seconds 3
}

Write-Host '[1/6] launching the game...' -ForegroundColor Cyan
if(-not $Direct){
    Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList ('/Y:"' + $prof + '"') -WorkingDirectory $rt | Out-Null
} else {
    Start-Process -FilePath $game -WorkingDirectory $gdir | Out-Null
}

Write-Host ('[2/6] waiting for the front end (up to {0}s)...' -f $MenuWait)
$t0 = Get-Date
$menuSeen = $false
while(((Get-Date) - $t0).TotalSeconds -lt $MenuWait){
    if(-not (Get-Process -Name Hedz -ErrorAction SilentlyContinue)){
        $phases.Add("$(T) game exited before the front end appeared")
        $menuSeen = $false
        break
    }
    $w = Get-HedzWindows
    if(@($w | Where-Object { $_.Class -eq '#32770' }).Count -gt 0){
        $menuSeen = $true
        $phases.Add("$(T) front end up after {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
        Write-Host ('      front end is up after {0:N1}s' -f ((Get-Date) - $t0).TotalSeconds) -ForegroundColor Green
        break
    }
    Start-Sleep -Milliseconds 400
}
if(-not $menuSeen -and -not $phases.Count){ $phases.Add("$(T) front end never detected") }

Write-Host ('[3/6] waiting for a level to start (up to {0}s)...' -f $LevelWait)
Write-Host '      >>> CLICK NEW GAME NOW and pick a level. <<<' -ForegroundColor Green
$t1 = Get-Date
$inLevel = $false
while(((Get-Date) - $t1).TotalSeconds -lt $LevelWait){
    if(-not (Get-Process -Name Hedz -ErrorAction SilentlyContinue)){
        $phases.Add("$(T) GAME EXITED before any level started")
        break
    }
    $w = Get-HedzWindows
    if(@($w | Where-Object { $_.Class -eq '#32770' }).Count -eq 0){
        $inLevel = $true
        $phases.Add("$(T) front-end dialog gone after {0:N1}s -> level entering" -f ((Get-Date) - $t1).TotalSeconds)
        Write-Host '      level entry detected - capturing' -ForegroundColor Green
        break
    }
    Start-Sleep -Milliseconds 500
}
if(-not $inLevel){ $phases.Add("$(T) no level entry within {0}s - capturing anyway" -f $LevelWait) }

Start-Sleep -Seconds 2

Write-Host ('[4/6] capturing for up to {0}s...' -f $Seconds) -ForegroundColor Cyan
Write-Host '      >>> PLAY THE LEVEL NOW. Move around. <<<' -ForegroundColor Green
Start-Process -FilePath $pm -ArgumentList '/AcceptEula','/Quiet','/Minimized','/BackingFile',$pml
Start-Sleep -Seconds 4
if(-not (Get-Process -Name Procmon64,Procmon -ErrorAction SilentlyContinue)){ throw 'ProcMon did not start.' }

$start   = Get-Date
$lastState = $null
while(((Get-Date) - $start).TotalSeconds -lt $Seconds){
    if(-not (Get-Process -Name Hedz -ErrorAction SilentlyContinue)){
        $phases.Add("$(T) GAME EXITED - stopping capture early after {0:N0}s" -f ((Get-Date) - $start).TotalSeconds)
        Write-Host '      game exited - stopping capture early' -ForegroundColor Yellow
        break
    }
    $w = Get-HedzWindows
    $state = (($w | Sort-Object Class | ForEach-Object { '{0}/{1}/vis={2}' -f $_.Class,$_.Title,[int]$_.Visible }) -join ' | ')
    if($state -ne $lastState){ $phases.Add("$(T) windows: $state"); $lastState = $state }
    Start-Sleep -Milliseconds 700
}
$phases.Add("$(T) capture window ended")

Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
if($dxServer){ Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/E' -WorkingDirectory $rt | Out-Null }
Start-Sleep -Seconds 1

Write-Host '[5/6] stopping capture...' -ForegroundColor Cyan
& $pm /Terminate | Out-Null
Start-Sleep -Seconds 3
Write-Host '[6/6] exporting + pruning...' -ForegroundColor Cyan
& $pm /OpenLog $pml /SaveAs $csv /Quiet | Out-Null
Start-Sleep -Seconds 5
Get-Process -Name Procmon64,Procmon -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
if(-not (Test-Path $csv)){ throw "CSV not produced at $csv" }
Write-Host ("      CSV: {0:N0} bytes" -f (Get-Item $csv).Length)

# ---- prune: streaming reader, hedZ.exe lines only ----
$kept = 0
$sr = [IO.File]::OpenText($csv)
$sw = [IO.File]::CreateText($pruned)
try{
    while($null -ne ($line = $sr.ReadLine())){
        if($line.IndexOf('"Hedz.exe"') -ge 0){ $sw.WriteLine($line); $kept++ }
    }
} finally { $sr.Close(); $sw.Close() }
Write-Host ("      kept {0:N0} Hedz.exe events" -f $kept) -ForegroundColor Cyan
foreach($big in $pml,$csv){ if(Test-Path $big){ Remove-Item $big -Force -ErrorAction SilentlyContinue } }
Write-Host '      large trace files removed'

# ---------------- analyse the pruned file ----------------
$musOps  = New-Object System.Collections.Generic.List[string]
$musBytes= @{}
$dOpens  = New-Object System.Collections.Generic.List[string]
$creates = @{}
$reads   = @{}
$mods    = New-Object System.Collections.Generic.List[string]
$fails   = New-Object System.Collections.Generic.List[string]
$procs   = New-Object System.Collections.Generic.List[string]
$total   = 0

$sr2 = [IO.File]::OpenText($pruned)
try{
    while($null -ne ($line = $sr2.ReadLine())){
        $total++
        $f = $line.Split(@('","'),[StringSplitOptions]::None)
        if($f.Count -lt 6){ continue }
        $tm   = $f[0].TrimStart('"')
        $proc = $f[1]
        $op   = $f[3]
        $path = $f[4]
        $res  = $f[5]
        $det  = if($f.Count -gt 6){ ($f[6] -replace '"\s*$','') } else { '' }

        if($op -like 'Process *'){ $procs.Add(("  {0}  {1}  {2}" -f $tm,$op,$det)) }
        if($op -eq 'Load Image'){ $mods.Add(("  {0}  {1}" -f $tm,$path)) }
        if($op -eq 'CreateFile'){ $creates[$path] = 1 + $(if($creates.ContainsKey($path)){$creates[$path]}else{0}) }
        if($op -eq 'ReadFile'){
            $reads[$path] = 1 + $(if($reads.ContainsKey($path)){$reads[$path]}else{0})
        }
        if($path -match '(?i)(\.mus|\.amb|music)'){
            $musOps.Add(("{0}  {1,-26} {2}  ->  {3}{4}" -f $tm,$op,$path,$res,$(if($det -and $op -match '(?i)^ReadFile$'){"  [$det]"}else{''})))
            if($op -eq 'ReadFile'){
                if($det -match '(?i)Length:\s*([0-9,]+)'){
                    $n = [int64](($Matches[1]) -replace ',','')
                    $musBytes[$path] = $n + $(if($musBytes.ContainsKey($path)){$musBytes[$path]}else{0})
                }
            }
        }
        if($path -match '(?i)^D:' -and $op -eq 'CreateFile'){ $dOpens.Add(("  {0}  {1}  ->  {2}" -f $tm,$path,$res)) }
        if($res -notmatch '(?i)^(SUCCESS|REPARSEPOINT|OPLOCK|PENDING|FAST IO|END OF FILE|BUFFER OVERFLOW|NO MORE ENTRIES|NOT REPARSE POINT|BUFFER TOO SMALL|FILE LOCKED WITH ONLY READERS|NAME COLLISION|DISK FULL|MEDIA WRITE PROTECTED|FILE CLOSED|INVALID DEVICE REQUEST)$'){
            $fails.Add(("  {0,-24} {1}  ->  {2}" -f $op,$path,$res))
        }
    }
} finally { $sr2.Close() }

$rep = Join-Path $out 'music-report.txt'
$sb  = New-Object System.Text.StringBuilder
function W($s){ Write-Host $s; [void]$sb.AppendLine($s) }

W ("H.E.D.Z. level-music capture - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ("pruned events: {0:N0}" -f $total)
W ''
W '=============== PHASE TIMELINE (window states) ==============='
$phases | ForEach-Object { W ('  ' + $_) }

W ''
W '=============== PROCESS EVENTS ==============='
if($procs.Count){ $procs | ForEach-Object { W $_ } } else { W '  (none)' }

W ''
W '=============== MUSIC / AMB / MUS OPERATIONS - CHRONOLOGICAL ==============='
W '  (which file is touched, when, and with what result)'
if($musOps.Count){
    $musOps | Select-Object -First 150 | ForEach-Object { W ('  ' + $_) }
    if($musOps.Count -gt 150){ W ("  ... {0} more" -f ($musOps.Count-150)) }
} else {
    W '  *** NO music-related file operation at all ***'
    W '  The music system never even tried to open a track.'
}
W ''
W '  --- music files touched, with read volume ---'
if($musBytes.Count){
    foreach($k in ($musBytes.Keys | Sort-Object)){ W ("    {0,-42} {1,15:N0} bytes streamed" -f $k,$musBytes[$k]) }
} else { W '    (no reads on any music file)' }

W ''
W '=============== DISC (D:) OPENS ==============='
if($dOpens.Count){ $dOpens | Select-Object -First 60 | ForEach-Object { W $_ } } else { W '  (nothing opened on D:)' }

W ''
W '=============== FILES OPENED, BY COUNT (top 40) ==============='
$creates.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 40 |
    ForEach-Object { W ("  [{0,4}x] {1}" -f $_.Value,$_.Key) }

W ''
W '=============== FILES READ, BY READ-OP COUNT (top 30) ==============='
$reads.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 30 |
    ForEach-Object { W ("  [{0,5}x] {1}" -f $_.Value,$_.Key) }

W ''
W '=============== MODULES LOADED ==============='
if($mods.Count){ $mods | Select-Object -Unique | ForEach-Object { W $_ } } else { W '  (none)' }

W ''
W '=============== FAILED OPERATIONS OF INTEREST ==============='
$interesting = $fails | Where-Object { $_ -notmatch '(?i)(HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\(DirectDraw|Direct3D|DirectInput)|Microsoft\\Cryptography|SystemCertificates|FolderDescriptions|Nls\\|PruningMode|bam\\State|Video[0-9]+|IsVailContainer|Audio\\DevApi|Monitor|EDID)' }
if($interesting.Count){ ($interesting | Select-Object -Unique | Sort-Object) | Select-Object -First 80 | ForEach-Object { W $_ } }
else { W '  (nothing but the usual DirectX/COM probe chatter)' }

[IO.File]::WriteAllText($rep,$sb.ToString())
Write-Host ''
Write-Host ("report saved: {0}" -f $rep) -ForegroundColor Green

if($restorePal -and (Test-Path $pddOff)){ Move-Item $pddOff $pdd -Force; Write-Host 'pal-ddraw restored.' -ForegroundColor DarkGray }
Write-Host ''
Write-Host 'Done. Tell the agent the run finished.' -ForegroundColor Green
