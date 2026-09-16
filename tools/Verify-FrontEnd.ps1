#Requires -Version 5.1
<#
.SYNOPSIS
    Verify-FrontEnd.ps1 - decide whether H.E.D.Z. is really "a black screen" or
    simply sitting at its main menu.

.DESCRIPTION
    Probing earlier showed the game reaches its front end: it creates a standard
    dialog (#32770, title "H.E.D.Z.") containing the buttons

        New Game | Multi-Player Game | Play Movies | Difficulty Settings | Options | Exit

    and then waits (thread wait reason UserRequest) - it does not crash and it
    does not exit by itself. This script waits for that menu to appear, then
    measures the SCREEN, so "black screen" can be distinguished from "worked
    fine, background happens to be dark":

      * full-screen pixel statistics (share of near-black, distinct colours)
      * the game's own render window (class 'Vis Interactive') and whether it
        is visible or hidden, with its rectangle
      * a coarse luminance map of the whole desktop
      * full-screen PNG saved for a human to look at

    The game window appears briefly and is closed automatically. Read-only.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$WaitSeconds = 25,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'trace' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class FePeek
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public class WinInfo { public long Handle; public string ClassName; public string Title; public bool Visible; public int X, Y, W, H; public int Style; }

    static WinInfo Describe(IntPtr h)
    {
        var w = new WinInfo();
        var sb = new StringBuilder(512);
        GetClassName(h, sb, 512);  w.ClassName = sb.ToString();
        sb.Clear();
        GetWindowText(h, sb, 512); w.Title = sb.ToString();
        w.Handle = h.ToInt64();
        w.Visible = IsWindowVisible(h);
        RECT r; GetWindowRect(h, out r);
        w.X = r.Left; w.Y = r.Top; w.W = r.Right - r.Left; w.H = r.Bottom - r.Top;
        w.Style = GetWindowLong(h, -16);
        return w;
    }

    public static List<WinInfo> TopLevel(int pid)
    {
        var list = new List<WinInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid == (uint)pid) list.Add(Describe(h));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static List<string> ChildTexts(long parent)
    {
        var list = new List<string>();
        EnumChildWindows(new IntPtr(parent), delegate(IntPtr h, IntPtr p)
        {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.Length > 0) list.Add(sb.ToString());
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool IsForeground(long h) { return GetForegroundWindow().ToInt64() == h; }
}
'@

if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }

Write-Host '=== waiting for the H.E.D.Z. front end ===' -ForegroundColor Cyan
$proc = Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) -PassThru
$gpid = $proc.Id
Write-Host ("pid {0}" -f $gpid)

$menu = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Id $gpid -ErrorAction SilentlyContinue)) { Write-Host '  process exited early'; break }
    $tops = [FePeek]::TopLevel($gpid)
    $dlg = $tops | Where-Object { $_.ClassName -eq '#32770' -and $_.Visible } | Select-Object -First 1
    if ($dlg) {
        $txts = [FePeek]::ChildTexts($dlg.Handle)
        if ($txts -contains 'New Game') { $menu = $dlg; break }
    }
}

if (-not $menu) {
    Write-Host '  front-end menu did not appear in time.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host '  FRONT END REACHED - menu dialog is up:' -ForegroundColor Green
    Write-Host ("    title  : '{0}'   rect {1},{2} {3}x{4}   foreground={5}" -f `
        $menu.Title, $menu.X, $menu.Y, $menu.W, $menu.H, [FePeek]::IsForeground($menu.Handle))
    Write-Host ("    options: {0}" -f (([FePeek]::ChildTexts($menu.Handle)) -join ' | '))
}

Write-Host ''
Write-Host '=== all windows owned by the game ===' -ForegroundColor Cyan
foreach ($t in [FePeek]::TopLevel($gpid)) {
    $note = ''
    if ($t.ClassName -eq 'Vis Interactive') { $note = '   <-- the DirectDraw render window' }
    Write-Host ("  class='{0}' title='{1}' visible={2} {3},{4} {5}x{6} style=0x{7:X8}{8}" -f `
        $t.ClassName, $t.Title, $t.Visible, $t.X, $t.Y, $t.W, $t.H, $t.Style, $note)
}

# ---- full screen measurement ----
Write-Host ''
Write-Host '=== FULL SCREEN measurement (is it really black?) ===' -ForegroundColor Cyan
try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
}
try {
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, (New-Object System.Drawing.Size($vs.Width, $vs.Height)))
    $png = Join-Path $OutDir 'hedz-fullscreen.png'
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host ("  screen {0}x{1}  saved {2}" -f $vs.Width, $vs.Height, $png)

    $distinct = @{}; $black = 0; $total = 0
    for ($y = 0; $y -lt $vs.Height; $y += 4) {
        for ($x = 0; $x -lt $vs.Width; $x += 4) {
            $c = $bmp.GetPixel($x, $y)
            $lum = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            $total++
            if ($lum -lt 20) { $black++ }
            $k = ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
            if ($distinct.ContainsKey($k)) { $distinct[$k]++ } else { $distinct[$k] = 1 }
        }
    }
    Write-Host ("  sampled {0} px   near-black: {1:N1} %   distinct colours: {2}" -f `
        $total, (100.0 * $black / [Math]::Max($total, 1)), $distinct.Count)
    Write-Host '  top colours:'
    $distinct.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 |
        ForEach-Object { Write-Host ("      #{0}  x{1}  ({2:N1} %)" -f $_.Key, $_.Value, (100.0 * $_.Value / $total)) }

    Write-Host ''
    Write-Host '  desktop luminance map (96x30; "."=black, "#"=bright):'
    for ($ry = 0; $ry -lt 30; $ry++) {
        $line = ''
        for ($rx = 0; $rx -lt 96; $rx++) {
            $sx = [int]($rx * $vs.Width / 96); $sy = [int]($ry * $vs.Height / 30)
            $c = $bmp.GetPixel([Math]::Min($sx, $vs.Width - 1), [Math]::Min($sy, $vs.Height - 1))
            $lum = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            $line += if ($lum -lt 20) { '.' } elseif ($lum -lt 80) { ':' } elseif ($lum -lt 170) { '+' } else { '#' }
        }
        Write-Host ('    ' + $line)
    }
    $g.Dispose(); $bmp.Dispose()
} catch {
    Write-Host ("  screen capture failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'closing the game...'
Get-Process -Id $gpid -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
