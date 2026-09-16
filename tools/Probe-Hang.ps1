#Requires -Version 5.1
<#
.SYNOPSIS
    Probe-Hang.ps1 - look inside H.E.D.Z. while it sits on the black screen.

.DESCRIPTION
    After the disc check the game opens D:\Hedz\Movies\VISident.avi, enumerates
    DirectDraw display drivers, then burns no CPU at all for ~8 seconds before
    exiting with code 0. "No CPU" means it is BLOCKED, not looping, so the
    useful question is: blocked on what, and in which thread?

    While the game is in that state this samples, once per second:

      * CPU (user/kernel), working set, private bytes, handle/thread counts
      * every top-level window the process owns: class, title, visibility,
        position and size (a stray off-screen or 0x0 window is a strong hint)
      * every loaded module (is TruePlay.dll / d3dim.dll / ddraw.dll in? is a
        codec DLL being pulled in?)
      * a full per-thread dump: state, wait reason and CPU

    The game window appears briefly and is closed automatically. Read-only.
#>
[CmdletBinding()]
param(
    [string]$GameExe  = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$SampleSeconds = 16,
    [int]$DumpThreadsAt = 6
)

$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WinEnum
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public class WinInfo
    {
        public long Handle;
        public string ClassName;
        public string Title;
        public bool Visible;
        public int X, Y, W, H;
        public int Style;
    }

    public static List<WinInfo> ForProcess(int pid)
    {
        var list = new List<WinInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            uint wpid;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid != (uint)pid) return true;
            var ci = new WinInfo();
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256); ci.ClassName = sb.ToString();
            sb.Clear();
            GetWindowText(h, sb, 256); ci.Title = sb.ToString();
            ci.Handle = h.ToInt64();
            ci.Visible = IsWindowVisible(h);
            RECT r; GetWindowRect(h, out r);
            ci.X = r.Left; ci.Y = r.Top; ci.W = r.Right - r.Left; ci.H = r.Bottom - r.Top;
            ci.Style = GetWindowLong(h, -16);
            list.Add(ci);
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }

Write-Host '=== launching and sampling ===' -ForegroundColor Cyan
$proc = Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) -PassThru
$pid2 = $proc.Id
Write-Host ("pid {0}" -f $pid2)

$dumpedThreads = $false
$dumpedModules = $false
for ($s = 1; $s -le $SampleSeconds; $s++) {
    Start-Sleep -Seconds 1
    $p = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Host ("  [{0,2}s] process has exited" -f $s)
        break
    }
    $cpu = $p.TotalProcessorTime.TotalSeconds
    $thr = ($p.Threads | Measure-Object).Count
    Write-Host ("  [{0,2}s] alive  cpu={1:N3}s  ws={2:N0}KB  priv={3:N0}KB  threads={4}  handles={5}" -f `
        $s, $cpu, ($p.WorkingSet64 / 1KB), ($p.PrivateMemorySize64 / 1KB), $thr, $p.HandleCount)

    try {
        $wins = [WinEnum]::ForProcess($pid2)
        Write-Host ("        windows: {0}" -f $wins.Count)
        foreach ($w in $wins) {
            Write-Host ("          class='{0}' title='{1}' vis={2} rect={3},{4} {5}x{6} style=0x{7:X8}" -f `
                $w.ClassName, $w.Title, $w.Visible, $w.X, $w.Y, $w.W, $w.H, $w.Style)
        }
    } catch { Write-Host ("        window enum failed: {0}" -f $_.Exception.Message) }

    if (-not $dumpedModules -and $s -ge 3) {
        $dumpedModules = $true
        try {
            $mods = $p.Modules | ForEach-Object { $_.ModuleName } | Where-Object {
                $_ -match '(?i)trueplay|d3dim|ddraw|dsound|dinput|mss|dplayx|dciman|quartz|msvfw|iccvid|ir50|divx|xvid|devenum|d3d9|d3d8|nvwgf|nvd3d|igd|avi|vfw'
            }
            Write-Host ("        graphics/media modules: {0}" -f (($mods | Sort-Object -Unique) -join ', '))
        } catch { Write-Host '        (module list unavailable)' }
    }

    if (-not $dumpedThreads -and $s -ge $DumpThreadsAt) {
        $dumpedThreads = $true
        Write-Host ''
        Write-Host ("  --- per-thread detail at {0}s (what is it blocked ON?) ---" -f $s) -ForegroundColor Yellow
        foreach ($t in $p.Threads) {
            $addr = '?'
            try { $addr = ('0x{0:X}' -f $t.StartAddress.ToInt64()) } catch { }
            Write-Host ("        tid={0,-7} state={1,-12} wait={2,-18} cpu={3:N3}s start={4}" -f `
                $t.Id, $t.ThreadState, $t.WaitReason, $t.TotalProcessorTime.TotalSeconds, $addr)
        }
        Write-Host ''
    }
}

$p = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
if ($p) { Write-Host 'killing (still running)'; $p.Kill() }
else {
    Write-Host ''
    Write-Host ("GAME EXITED with code {0}" -f $proc.ExitCode) -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== current compatibility flags for Hedz.exe ===' -ForegroundColor Cyan
foreach ($k in 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
               'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') {
    if (-not (Test-Path $k)) { continue }
    (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -match '(?i)hedz' } |
        ForEach-Object { Write-Host ("  {0}  =>  {1}" -f $_.Name, $_.Value) }
}
