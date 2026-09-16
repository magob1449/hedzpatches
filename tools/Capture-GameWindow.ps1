<#
.SYNOPSIS
    Capture-GameWindow.ps1 - captures the screen during the phase where the real
    game window ('Vis Interactive'/'Hedz') is up, and measures whether it is
    actually black.

    Context: Watch-HedzWindows.ps1 showed the app spends ~15 s on a front-end
    dialog and then opens a 1920x1080 window which exits ~9 s later with code 0.
    The earlier full-screen histogram was taken during the DIALOG phase, which is
    why it showed the desktop and 1600+ colours. This one waits for the game
    window, then measures.

    Writes .\tools\_gwin.png and .\tools\_gwin.out.
#>
param(
    [int]$WaitForWindow = 17,   # seconds before capturing (game window is up by ~16)
    [int]$WatchTo       = 60    # keep observing this long to catch the exit
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe = 'C:\GAMES\HEDZ\Hedz.exe'
$dir = Split-Path $exe -Parent
$png = Join-Path $PSScriptRoot '_gwin.png'
$out = Join-Path $PSScriptRoot '_gwin.out'

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W3 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }

$p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
Say ("pid {0}" -f $p.Id)
Start-Sleep -Seconds $WaitForWindow
Say ("--- capture at t~{0}s (HasExited={1}) ---" -f $WaitForWindow, $p.HasExited)

$fg = [W3]::GetForegroundWindow()
Say ("foreground window class = '{0}'" -f [W3]::Cls($fg))

$script:mine = New-Object System.Collections.ArrayList
$script:wp = $p.Id
$cb = [W3+EnumProc]{
    param($h,$l)
    $o = 0; [void][W3]::GetWindowThreadProcessId($h, [ref]$o)
    if ($o -eq $script:wp) {
        $r = New-Object W3+R; [void][W3]::GetWindowRect($h, [ref]$r)
        [void]$script:mine.Add([pscustomobject]@{
            H=$h; Class=[W3]::Cls($h); Vis=[W3]::IsWindowVisible($h)
            X=$r.L; Y=$r.T; W=($r.Rt-$r.L); Hh=($r.B-$r.T) })
    }
    return $true
}
[void][W3]::EnumWindows($cb, [IntPtr]::Zero)
$vis = $script:mine | Where-Object { $_.Vis }
Say ("visible windows: {0}" -f @($vis).Count)
$vis | ForEach-Object { Say ("  class='{0}' {1},{2} {3}x{4}" -f $_.Class,$_.X,$_.Y,$_.W,$_.Hh) }

$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
Say ("saved {0}" -f $png)

function Analyze([string]$label,[int]$x,[int]$y,[int]$w,[int]$h){
  if($w -le 0 -or $h -le 0){ return }
  $x=[Math]::Max(0,$x); $y=[Math]::Max(0,$y)
  $x2=[Math]::Min($bounds.Width,$x+$w); $y2=[Math]::Min($bounds.Height,$y+$h)
  $t=0;$b=0;$cols=@{}
  for($py=$y;$py -lt $y2;$py+=4){ for($px=$x;$px -lt $x2;$px+=4){
      $c=$bmp.GetPixel($px,$py); $t++
      if($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16){$b++}
      $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
      if($cols.ContainsKey($k)){$cols[$k]++}else{$cols[$k]=1}
  }}
  if($t -eq 0){return}
  Say ("  {0}: {1}px sampled, near-black {2}%, distinct colours {3}" -f $label,$t,[Math]::Round(100*$b/$t,1),$cols.Count)
  $cols.GetEnumerator()|Sort-Object -Property Value -Descending|Select-Object -First 6|ForEach-Object{
    Say ("      #{0} {1}%" -f $_.Key,[Math]::Round(100*$_.Value/$t,1)) }
}
Say '--- pixel analysis ---'
Analyze 'whole screen' 0 0 $bounds.Width $bounds.Height
$bw = $vis | Sort-Object -Property { $_.W * $_.Hh } -Descending | Select-Object -First 1
if ($bw) { Say ("  largest game window: class='{0}' {1},{2} {3}x{4}" -f $bw.Class,$bw.X,$bw.Y,$bw.W,$bw.Hh)
           Analyze ("game window '" + $bw.Class + "'") $bw.X $bw.Y $bw.W $bw.Hh }
else { Analyze 'centre 640x480' 640 200 640 480 }
$bmp.Dispose()

Say '--- watching for exit ---'
for ($i = $WaitForWindow; $i -lt $WatchTo; $i++) {
    Start-Sleep -Seconds 1
    if ($p.HasExited) { Say ("EXITED at ~{0}s  code={1}" -f ($i+1), $p.ExitCode); break }
}
if (-not $p.HasExited) { Say ("still alive at {0}s" -f $WatchTo); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

[IO.File]::WriteAllLines($out, $lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
