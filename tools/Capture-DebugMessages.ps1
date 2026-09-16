<#
.SYNOPSIS
    Capture-DebugMessages.ps1 - records everything H.E.D.Z. says on the Windows
    debug channel (OutputDebugString) while you play.

.DESCRIPTION
    Why this exists. The game demonstrably never opens a level-music file when a
    level is played:

      * In the front end it streams D:\Hedz\Music\F.MUS off the disc (240 reads
        captured) - the title music works.
      * F.MUS stops the moment a level starts, and during 82 seconds of level
        play NOTHING music-related is opened at all - no <n>.mus, no <n>.AMB.

    So the level-music subsystem is not failing to read a track; it never asks.
    Hedz.exe imports OutputDebugStringA and carries a full narration for exactly
    this subsystem - "AUDIO INFO: [MUS V2.0] Music path is: %s:",
    "Entering Music Area - %d", "Starting Interactive Music - Setup",
    "Failed to open music data file: %s" - so the game can be made to explain
    itself instead of us inferring.

    Implementation: the classic DBWIN_BUFFER protocol. Create the "DBWIN_BUFFER"
    file mapping and the DBWIN_BUFFER_READY / DBWIN_DATA_READY events, then wait
    on the data event and read [pid][string] out of the buffer. The listener MUST
    exist before the game starts, which is why this script launches the game
    itself.

    This is a very light capture compared with Process Monitor: no kernel filter
    driver, no system-wide event stream, no multi-hundred-megabyte CSV.

.NOTES
    Runs unelevated (the game it launches is unelevated too - a higher-integrity
    game would be invisible to a medium-integrity listener). Writes
    tools\trace\debug-messages.txt.
#>
[CmdletBinding()]
param(
    [int]$Seconds = 180,                                  # how long to listen (or until the game exits)
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$KeepPalDdraw,
    [switch]$Direct,                                       # launch the exe directly (no DxWnd)
    [switch]$Detach                                        # re-launch in a new visible window and return
)

$ErrorActionPreference = 'Continue'

if($Detach){
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Seconds',$Seconds)
    if($KeepPalDdraw){ $argl += '-KeepPalDdraw' }
    if($Direct){ $argl += '-Direct' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -WorkingDirectory $PSScriptRoot | Out-Null
    Write-Host 'Debug listener re-launched in its own window.'
    exit 0
}

$kit  = $PSScriptRoot
$rt   = Join-Path $kit 'dxwnd\runtime'
$prof = Join-Path $kit 'dxwnd\HEDZ.dxw'
$out  = Join-Path $kit 'trace'
if(-not (Test-Path $out)){ New-Item -ItemType Directory -Path $out -Force | Out-Null }
$log  = Join-Path $out 'debug-messages.txt'
$sum  = Join-Path $out 'debug-summary.txt'

if(-not ('DbgWin' -as [type])){
    Add-Type -Namespace '' -Name 'DbgWin' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr CreateFileMapping(IntPtr hFile, IntPtr lpAttributes, uint flProtect, uint dwMaximumSizeHigh, uint dwMaximumSizeLow, string lpName);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, IntPtr dwNumberOfBytesToMap);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr CreateEvent(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetEvent(IntPtr hEvent);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr hObject);
'@
}

# ---- claim the debug buffer BEFORE the game starts ----
$INVALID   = [IntPtr](-1)
$PAGE_RW   = 0x04
$MAP_READ  = 0x0004
$SIZE      = 4096

$hMap  = [DbgWin]::CreateFileMapping($INVALID,[IntPtr]::Zero,$PAGE_RW,0,$SIZE,'DBWIN_BUFFER')
$err   = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
if($hMap -eq [IntPtr]::Zero){ throw ("Could not create DBWIN_BUFFER (win32 error {0}) - another debug listener may own it." -f $err) }
$shared = ($err -eq 183)   # ERROR_ALREADY_EXISTS
$pBuf  = [DbgWin]::MapViewOfFile($hMap,$MAP_READ,0,0,[IntPtr]$SIZE)
if($pBuf -eq [IntPtr]::Zero){ throw 'MapViewOfFile failed.' }
$hReady = [DbgWin]::CreateEvent([IntPtr]::Zero,$false,$false,'DBWIN_BUFFER_READY')
$hData  = [DbgWin]::CreateEvent([IntPtr]::Zero,$false,$false,'DBWIN_DATA_READY')
if($hReady -eq [IntPtr]::Zero -or $hData -eq [IntPtr]::Zero){ throw 'Could not create the DBWIN events.' }
[void][DbgWin]::SetEvent($hReady)

$sw = New-Object IO.StreamWriter($log,$false)
$sw.AutoFlush = $true

Write-Host '===============================================================' -ForegroundColor Yellow
Write-Host ' H.E.D.Z. debug-channel capture' -ForegroundColor Yellow
Write-Host '===============================================================' -ForegroundColor Yellow
Write-Host ("listener ready{0}" -f $(if($shared){' (WARNING: another listener held DBWIN_BUFFER - messages may be split)'}else{''}))
Write-Host 'The game will start at 800x600. Click NEW GAME, pick a level and PLAY.' -ForegroundColor Green
Write-Host 'About a minute in the level is plenty. You can quit the game when done.' -ForegroundColor Green
Write-Host ''

# ---- one authoritative DirectDraw layer, then launch ----
$gameDir = Split-Path $GameExe -Parent
$pdd     = Join-Path $gameDir 'DDRAW.dll'
$pddOff  = Join-Path $gameDir 'DDRAW.dll.pal-ddraw-disabled'
$restore = $false
if(-not $KeepPalDdraw -and (Test-Path $pdd)){
    if(Test-Path $pddOff){ Remove-Item $pddOff -Force }
    Move-Item $pdd $pddOff -Force
    $restore = $true
    Write-Host 'pal-ddraw retired for this session' -ForegroundColor Yellow
}

Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
$dxServer = $null
if($Direct){
    Start-Process -FilePath $GameExe -WorkingDirectory $gameDir | Out-Null
  } else {
    if(-not (Test-Path (Join-Path $rt 'dxwnd.exe'))){ throw 'DxWnd not deployed - run tools\Install-DxWnd.ps1' }
    Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} }
    Start-Sleep -Milliseconds 700
    $dxServer = Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/T','/Q' -WorkingDirectory $rt -PassThru
    Start-Sleep -Seconds 3
    Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList ('/Y:"' + $prof + '"') -WorkingDirectory $rt | Out-Null
}
Write-Host 'game launched - listening...' -ForegroundColor Cyan

# ---- listen ----
$t0 = Get-Date
$count = 0
$byPid = @{}
$lines = New-Object System.Collections.Generic.List[string]
while(((Get-Date) - $t0).TotalSeconds -lt $Seconds){
    $r = [DbgWin]::WaitForSingleObject($hData,250)
    if($r -eq 0){
        $pid_ = [Runtime.InteropServices.Marshal]::ReadInt32($pBuf)
        $msg  = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($pBuf,4))
        [void][DbgWin]::SetEvent($hReady)
        $line = ('[{0:HH:mm:ss.fff}] [{1}] {2}' -f (Get-Date),$pid_,$msg)
        $sw.WriteLine($line)
        $lines.Add($line); $count++
        $byPid[$pid_] = 1 + $(if($byPid.ContainsKey($pid_)){$byPid[$pid_]}else{0})
    }
    if(-not (Get-Process -Name Hedz -ErrorAction SilentlyContinue)){
        $grace = (Get-Date)
        while(((Get-Date) - $grace).TotalSeconds -lt 3){   # drain anything still in flight
            if([DbgWin]::WaitForSingleObject($hData,200) -eq 0){
                $pid_ = [Runtime.InteropServices.Marshal]::ReadInt32($pBuf)
                $msg  = [Runtime.InteropServices.Marshal]::PtrToStringAnsi([IntPtr]::Add($pBuf,4))
                [void][DbgWin]::SetEvent($hReady)
                $line = ('[{0:HH:mm:ss.fff}] [{1}] {2}' -f (Get-Date),$pid_,$msg)
                $sw.WriteLine($line); $lines.Add($line); $count++
            }
        }
        Write-Host 'game exited - listener stopping' -ForegroundColor Yellow
        break
    }
}
$sw.Close()
if($dxServer){ Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { try{ $_.Kill() }catch{} } }
if($restore -and (Test-Path $pddOff)){ Move-Item $pddOff $pdd -Force; Write-Host 'pal-ddraw restored' -ForegroundColor DarkGray }
[void][DbgWin]::UnmapViewOfFile($pBuf)

# ---- summarise ----
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine(("H.E.D.Z. debug-channel capture - {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
[void]$sb.AppendLine(("messages: {0}   (listening {1:N0}s)" -f $count,((Get-Date)-$t0).TotalSeconds))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- messages by process id ---')
foreach($k in $byPid.Keys){ [void]$sb.AppendLine(("  pid {0}: {1}" -f $k,$byPid[$k])) }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- distinct messages (digits collapsed), by count ---')
$lines | ForEach-Object { ($_ -replace '^\[[^\]]*\]\s*\[[^\]]*\]\s*','') } |
    ForEach-Object { $_ -replace '\d+','#' } |
    Group-Object | Sort-Object Count -Descending | Select-Object -First 60 |
    ForEach-Object { [void]$sb.AppendLine(("  [{0,5}x] {1}" -f $_.Count,$_.Name)) }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- ALL messages mentioning music/audio/stream ---')
$lines | Where-Object { $_ -match '(?i)music|audio|stream|\.mus|\.amb|playlist|area' } |
    ForEach-Object { [void]$sb.AppendLine(('  ' + $_)) }
[IO.File]::WriteAllText($sum,$sb.ToString())

Write-Host ''
Write-Host ("captured {0} debug messages" -f $count) -ForegroundColor Green
Write-Host ("  raw     : {0}" -f $log)
Write-Host ("  summary : {0}" -f $sum)
