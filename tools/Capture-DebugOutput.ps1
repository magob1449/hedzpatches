#Requires -Version 5.1
<#
.SYNOPSIS
    Capture-DebugOutput.ps1 - record the debug strings H.E.D.Z. emits through
    OutputDebugStringA, which is how the game reports which init step failed.

.DESCRIPTION
    Hedz.exe imports OutputDebugStringA and contains the diagnostics

        "Failed to create window: exiting"
        "Failed to initialise DInput: exiting"
        "AppInit failed - exiting"
        "Create D3D viewport failed." / "SetViewport failed."
        "ERROR: ... disc is not a CD / wrong size / writeable"
        "AUDIO INFO: [MUS V2.0] Music path is: %s:"
        "TRUEPLAY: Deciding on movie to play"

    but never writes its c:\hedzdbg.txt log, so those messages were invisible.
    This implements the standard DBWIN_BUFFER shared-memory protocol to listen
    for them, launches the game, and prints everything it says with the source
    process id.

    The game window appears briefly and is closed automatically.

.NOTES
    Cannot read the buffer if another debug monitor (DbgView, VS debugger) is
    already attached - the script detects and reports that.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$Seconds = 25
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DbgCapture : IDisposable
{
    const uint PAGE_READWRITE = 0x04;
    const uint FILE_MAP_READ  = 0x0004;
    const uint WAIT_OBJECT_0  = 0x00000000;
    const int  ERROR_ALREADY_EXISTS = 183;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    static extern IntPtr CreateFileMappingA(IntPtr hFile, IntPtr lpAttr, uint flProtect,
                                            uint maxHigh, uint maxLow, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr MapViewOfFile(IntPtr hMap, uint access, uint offHigh, uint offLow, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    static extern IntPtr CreateEventA(IntPtr attr, bool manualReset, bool initialState, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetEvent(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UnmapViewOfFile(IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    IntPtr map = IntPtr.Zero, view = IntPtr.Zero, ready = IntPtr.Zero, dataReady = IntPtr.Zero;

    public bool Start(out string error)
    {
        error = null;
        map = CreateFileMappingA(new IntPtr(-1), IntPtr.Zero, PAGE_READWRITE, 0, 4096, "DBWIN_BUFFER");
        if (map == IntPtr.Zero) { error = "CreateFileMapping(DBWIN_BUFFER) failed"; return false; }
        if (Marshal.GetLastWin32Error() == ERROR_ALREADY_EXISTS)
        { error = "another debug-output monitor is already running (DbgView/VS/WinDbg?) - close it first"; return false; }

        view = MapViewOfFile(map, FILE_MAP_READ, 0, 0, new UIntPtr(4096));
        if (view == IntPtr.Zero) { error = "MapViewOfFile failed"; return false; }

        ready     = CreateEventA(IntPtr.Zero, false, true,  "DBWIN_BUFFER_READY");
        dataReady = CreateEventA(IntPtr.Zero, false, false, "DBWIN_DATA_READY");
        if (ready == IntPtr.Zero || dataReady == IntPtr.Zero) { error = "CreateEvent failed"; return false; }
        return true;
    }

    public bool Read(int timeoutMs, out int pid, out string text)
    {
        pid = 0; text = null;
        if (WaitForSingleObject(ready, (uint)timeoutMs) != WAIT_OBJECT_0) return false;
        pid = Marshal.ReadInt32(view);
        byte[] buf = new byte[4092];
        Marshal.Copy(new IntPtr(view.ToInt64() + 4), buf, 0, buf.Length);
        int len = Array.IndexOf(buf, (byte)0);
        if (len < 0) len = buf.Length;
        text = Encoding.ASCII.GetString(buf, 0, len);
        SetEvent(dataReady);
        return true;
    }

    public void Dispose()
    {
        if (view != IntPtr.Zero)      { UnmapViewOfFile(view);   view = IntPtr.Zero; }
        if (map != IntPtr.Zero)       { CloseHandle(map);        map = IntPtr.Zero; }
        if (ready != IntPtr.Zero)     { CloseHandle(ready);      ready = IntPtr.Zero; }
        if (dataReady != IntPtr.Zero) { CloseHandle(dataReady);  dataReady = IntPtr.Zero; }
    }
}
'@

Write-Host '=== capturing H.E.D.Z. debug output (OutputDebugStringA) ===' -ForegroundColor Cyan

$cap = New-Object DbgCapture
$err = $null
if (-not $cap.Start([ref]$err)) {
    Write-Host ('  could not start capture: ' + $err) -ForegroundColor Red
    exit 1
}
Write-Host '  capture active' -ForegroundColor Green

if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }

$gamePid = 0
$proc = Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) -PassThru
$gamePid = $proc.Id
Write-Host ("  launched pid {0}; listening for {1}s..." -f $gamePid, $Seconds) -ForegroundColor DarkGray

$deadline = (Get-Date).AddSeconds($Seconds)
$lines = New-Object System.Collections.Generic.List[string]
$exitedAt = $null

while ((Get-Date) -lt $deadline) {
    $pid2 = 0; $txt = $null
    if ($cap.Read(400, [ref]$pid2, [ref]$txt)) {
        if ($txt -ne $null) {
            $tag = if ($pid2 -eq $gamePid) { 'HEDZ' } else { ('pid ' + $pid2) }
            $entry = ('[{0,7:N2}s] [{1}] {2}' -f ((Get-Date) - $proc.StartTime).TotalSeconds, $tag, $txt)
            $lines.Add($entry)
        }
    }
    if (-not $exitedAt -and $proc.HasExited) {
        $exitedAt = (Get-Date)
        Write-Host ("  game exited after {0:N1}s with code {1} - draining remaining messages" -f `
            ($proc.ExitTime - $proc.StartTime).TotalSeconds, $proc.ExitCode) -ForegroundColor Yellow
        $deadline = (Get-Date).AddSeconds(2)
    }
}
$cap.Dispose()

Write-Host ''
Write-Host '=== captured debug output ===' -ForegroundColor Cyan
if ($lines.Count) {
    $lines | ForEach-Object { Write-Host ('  ' + $_) }
    $of = Join-Path $PSScriptRoot 'trace\hedz-debugoutput.txt'
    if (-not (Test-Path (Split-Path $of -Parent))) { New-Item -ItemType Directory -Path (Split-Path $of -Parent) -Force | Out-Null }
    $lines | Set-Content -Path $of -Encoding UTF8
    Write-Host ''
    Write-Host ("  saved: {0}" -f $of) -ForegroundColor Green
} else {
    Write-Host '  (nothing) - the game does not call OutputDebugStringA, or every' -ForegroundColor Yellow
    Write-Host '  listener slot was taken. Its diagnostics must come from elsewhere.' -ForegroundColor Yellow
}

Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
