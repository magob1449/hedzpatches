<#
.SYNOPSIS
    Capture-GameScreen.ps1 - captures hard evidence of what HEDZ actually puts on
    screen on Windows 11, and what display mode it selected.

    Why: the reported symptom is "black screen, then it closes", but a GDI
    foreground-window probe showed the front end alive and waiting. A screenshot
    plus window rectangles settles whether the DirectDraw surface is being
    presented or is genuinely black.

    Writes: .\tools\_creen.png  and  .\tools\_screen.out
    Read-only otherwise: starts the game, captures, stops it.
#>
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe = 'C:\GAMES\HEDZ\Hedz.exe'
$dir = Split-Path $exe -Parent
$png = Join-Path $PSScriptRoot '_screen.png'
$out = Join-Path $PSScriptRoot '_screen.out'

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
  public static string Txt(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }

# ---- 1. What the game last saved (it writes these after init) ----
Say '=== 1. Game-saved display settings (what it decided to use) ==='
foreach ($view in 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz','HKLM:\SOFTWARE\Vis Interactive\Hedz') {
    if (Test-Path $view) {
        Say ("  [{0}]" -f $view)
        (Get-ItemProperty $view).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object { Say ("     {0} = {1}" -f $_.Name, $_.Value) }
    }
}

# ---- 2. Launch, let it reach the front end ----
Say ''
Say '=== 2. Launch and capture ==='
$p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
Say ("  launched pid {0}" -f $p.Id)
Start-Sleep -Seconds 13
Say ("  HasExited after 13s = {0}" -f $p.HasExited)

# ---- 3. Windows belonging to the process ----
Say ''
Say '=== 3. Windows owned by the game process ==='
$mine = @()
$cb = [W+EnumProc]{
    param($h,$l)
    $pid2 = 0
    [void][W]::GetWindowThreadProcessId($h, [ref]$pid2)
    if ($pid2 -eq $p.Id) {
        $r = New-Object W+R
        [void][W]::GetWindowRect($h, [ref]$r)
        $mine += [pscustomobject]@{
            Handle = $h
            Class  = [W]::Cls($h)
            Title  = [W]::Txt($h)
            Vis    = [W]::IsWindowVisible($h)
            W      = $r.Rt - $r.L
            H      = $r.B - $r.T
            X      = $r.L
            Y      = $r.T
        }
    }
    return $true
}
[void][W]::EnumWindows($cb, [IntPtr]::Zero)
$mine | Sort-Object -Property Vis -Descending | ForEach-Object {
    Say ("  class='{0}' title='{1}' vis={2} rect={3},{4} {5}x{6}" -f $_.Class,$_.Title,$_.Vis,$_.X,$_.Y,$_.W,$_.H)
}

# ---- 4. Screenshot ----
Say ''
Say '=== 4. Full-screen capture ==='
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
Say ("  saved {0}  ({1}x{2})" -f $png, $bounds.Width, $bounds.Height)

# Region analysis: whole screen, and the largest visible game window
function Analyze([string]$label, [int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -le 0 -or $h -le 0) { return }
    $x = [Math]::Max(0,$x); $y = [Math]::Max(0,$y)
    $x2 = [Math]::Min($bounds.Width, $x+$w); $y2 = [Math]::Min($bounds.Height, $y+$h)
    $total = 0; $black = 0; $colors = @{}
    for ($py = $y; $py -lt $y2; $py += 4) {
        for ($px = $x; $px -lt $x2; $px += 4) {
            $c = $bmp.GetPixel($px, $py)
            $total++
            if ($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16) { $black++ }
            $key = '{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
            if ($colors.ContainsKey($key)) { $colors[$key]++ } else { $colors[$key] = 1 }
        }
    }
    if ($total -eq 0) { return }
    Say ("  {0}: sampled {1}px, near-black {2}%, distinct colours {3}" -f $label,$total,[Math]::Round(100*$black/$total,1),$colors.Count)
    $colors.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 8 | ForEach-Object {
        Say ("      #{0} {1}%" -f $_.Key,[Math]::Round(100*$_.Value/$total,1))
    }
}
Say ''
Say '=== 5. Region analysis ==='
Analyze 'whole screen' 0 0 $bounds.Width $bounds.Height
$big = $mine | Where-Object { $_.Vis } | Sort-Object -Property { $_.W * $_.H } -Descending | Select-Object -First 1
if ($big) {
    Say ("  largest visible window: class='{0}' title='{1}' {2}x{3}" -f $big.Class,$big.Title,$big.W,$big.H)
    Analyze ("window '" + $big.Class + "'") $big.X $big.Y $big.W $big.H
}
$bmp.Dispose()

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Say ''; Say '  (stopped)' }

[IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host ("report: {0}" -f $out)
