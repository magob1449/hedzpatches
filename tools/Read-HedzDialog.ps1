#Requires -Version 5.1
<#
.SYNOPSIS
    Read-HedzDialog.ps1 - read the modal dialog H.E.D.Z. puts up after the disc
    check, which is what the user is seeing as a "black screen".

.DESCRIPTION
    The game creates a standard #32770 dialog (title "H.E.D.Z.", 329x387) while
    its real window (class 'Vis Interactive') stays hidden, and the main thread
    waits with reason UserRequest - a classic modal message box.

    This waits for that dialog to appear and then reports:

      * every child control in the dialog: class, control id, position, TEXT
        (a Static control holds the message text - this is the answer)
      * the dialog's own window text, style flags and position
      * pixel statistics of the dialog area and the full screen
      * a coarse luminance map, so we can tell "blank black" from "has content"
      * a PNG screenshot of the dialog area, saved next to the reports

    The game window appears briefly and is closed automatically. Read-only.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$WaitSeconds = 20,
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

public static class DlgPeek
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public class WinInfo
    {
        public long Handle;
        public string ClassName;
        public string Title;
        public bool Visible;
        public bool Enabled;
        public int X, Y, W, H;
        public int Style;
        public int CtrlId;
    }

    static WinInfo Describe(IntPtr h)
    {
        var w = new WinInfo();
        var sb = new StringBuilder(1024);
        GetClassName(h, sb, 1024);  w.ClassName = sb.ToString();
        sb.Clear();
        GetWindowText(h, sb, 1024); w.Title = sb.ToString();
        w.Handle  = h.ToInt64();
        w.Visible = IsWindowVisible(h);
        w.Enabled = IsWindowEnabled(h);
        RECT r; GetWindowRect(h, out r);
        w.X = r.Left; w.Y = r.Top; w.W = r.Right - r.Left; w.H = r.Bottom - r.Top;
        w.Style = GetWindowLong(h, -16);
        w.CtrlId = GetDlgCtrlID(h);
        return w;
    }

    public static List<WinInfo> TopLevel(int pid, string onlyClass)
    {
        var list = new List<WinInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid != (uint)pid) return true;
            var w = Describe(h);
            if (onlyClass == null || w.ClassName == onlyClass) list.Add(w);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static List<WinInfo> Children(long parent)
    {
        var list = new List<WinInfo>();
        EnumChildWindows(new IntPtr(parent), delegate(IntPtr h, IntPtr p)
        {
            list.Add(Describe(h));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool IsForeground(long h) { return GetForegroundWindow().ToInt64() == h; }
}
'@

if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }

Write-Host '=== launching the game and waiting for its dialog ===' -ForegroundColor Cyan
$proc = Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) -PassThru
$gpid = $proc.Id
Write-Host ("pid {0}" -f $gpid)

$dialog = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $p = Get-Process -Id $gpid -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host '  process exited before a dialog appeared'; break }
    $tops = [DlgPeek]::TopLevel($gpid, '#32770')
    $vis = $tops | Where-Object { $_.Visible } | Select-Object -First 1
    if ($vis) { $dialog = $vis; break }
}

if ($dialog) {
    Write-Host ''
    Write-Host '=== DIALOG FOUND ===' -ForegroundColor Green
    Write-Host ("  handle  : 0x{0:X}" -f $dialog.Handle)
    Write-Host ("  class   : {0}" -f $dialog.ClassName)
    Write-Host ("  title   : '{0}'" -f $dialog.Title)
    Write-Host ("  rect    : {0},{1}  {2}x{3}" -f $dialog.X, $dialog.Y, $dialog.W, $dialog.H)
    Write-Host ("  style   : 0x{0:X8}   visible={1} enabled={2} foreground={3}" -f `
        $dialog.Style, $dialog.Visible, $dialog.Enabled, [DlgPeek]::IsForeground($dialog.Handle))

    Write-Host ''
    Write-Host '=== DIALOG CONTENTS (this is the message the game is showing) ===' -ForegroundColor Yellow
    $kids = [DlgPeek]::Children($dialog.Handle)
    if ($kids.Count -eq 0) {
        Write-Host '  (no child controls - the dialog is owner-drawn/empty; see pixel analysis)'
    } else {
        foreach ($k in $kids) {
            Write-Host ("  [{0,-14}] id={1,-6} {2},{3} {4}x{5} vis={6} enabled={7}" -f `
                $k.ClassName, $k.CtrlId, $k.X, $k.Y, $k.W, $k.H, $k.Visible, $k.Enabled)
            if ($k.Title) { Write-Host ("      TEXT: '{0}'" -f $k.Title) -ForegroundColor Green }
        }
    }

    # ---- screenshot + pixel analysis ----
    Write-Host ''
    Write-Host '=== PIXEL ANALYSIS + SCREENSHOT ===' -ForegroundColor Cyan
    try {
        $pad = 4
        $rect = New-Object System.Drawing.Rectangle(
            ($dialog.X - $pad), ($dialog.Y - $pad), ($dialog.W + 2 * $pad), ($dialog.H + 2 * $pad))
        $bmp = New-Object System.Drawing.Bitmap($rect.Width, $rect.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $rect.Size)
        $png = Join-Path $OutDir 'hedz-dialog.png'
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ("  screenshot: {0}  ({1}x{2})" -f $png, $rect.Width, $rect.Height) -ForegroundColor Green

        $distinct = @{}
        $dark = 0; $total = 0
        $w = $bmp.Width; $h = $bmp.Height
        for ($y = 0; $y -lt $h; $y += 2) {
            for ($x = 0; $x -lt $w; $x += 2) {
                $c = $bmp.GetPixel($x, $y)
                $lum = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
                $total++
                if ($lum -lt 24) { $dark++ }
                $key = ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
                if ($distinct.ContainsKey($key)) { $distinct[$key]++ } else { $distinct[$key] = 1 }
            }
        }
        Write-Host ("  sampled pixels : {0}" -f $total)
        Write-Host ("  distinct colors: {0}" -f $distinct.Count)
        Write-Host ("  near-black     : {0:N1} %" -f (100.0 * $dark / [Math]::Max($total, 1)))
        Write-Host '  top colors:'
        $distinct.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
            ForEach-Object { Write-Host ("      #{0}  x{1}" -f $_.Key, $_.Value) }

        Write-Host ''
        Write-Host '  luminance map (dark=".", bright="#") - shows whether content exists:'
        $cols = 96; $rows = 34
        for ($ry = 0; $ry -lt $rows; $ry++) {
            $line = ''
            for ($rx = 0; $rx -lt $cols; $rx++) {
                $sx = [int]($rx * $w / $cols)
                $sy = [int]($ry * $h / $rows)
                $c = $bmp.GetPixel([Math]::Min($sx, $w - 1), [Math]::Min($sy, $h - 1))
                $lum = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
                $line += if ($lum -lt 32) { '.' } elseif ($lum -lt 96) { ':' } elseif ($lum -lt 176) { '+' } else { '#' }
            }
            Write-Host ('    ' + $line)
        }
        $g.Dispose(); $bmp.Dispose()
    } catch {
        Write-Host ("  screenshot failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
} else {
    Write-Host ''
    Write-Host 'No visible #32770 dialog was found.' -ForegroundColor Yellow
    $tops = [DlgPeek]::TopLevel($gpid, $null)
    Write-Host 'All top-level windows owned by the process:'
    foreach ($t in $tops) {
        Write-Host ("  class='{0}' title='{1}' vis={2} {3},{4} {5}x{6}" -f `
            $t.ClassName, $t.Title, $t.Visible, $t.X, $t.Y, $t.W, $t.H)
    }
}

Write-Host ''
Write-Host 'closing the game...'
Get-Process -Id $gpid -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
