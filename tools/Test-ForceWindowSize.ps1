<#
.SYNOPSIS
    Test-ForceWindowSize.ps1 - forces HEDZ's render window down to 640x480 the
    moment it appears, to test the "window is too big for its surfaces" theory.

.DESCRIPTION
    Evidence so far: the game opens a window the size of the DESKTOP (1920x1080),
    fills it with pure #000000, and exits with code 0 ~9 s later. FullScreen and
    ResMode make no difference, and neither does the choice of DirectDraw
    provider. The kit's DxWnd profile prescribes Width=640 Height=480, and the
    exe's own string blames "a window of this size".

    So: resize the window ourselves, repeatedly, from the outside, and see if the
    game then renders a frame instead of pure black. Non-destructive - the game
    is stopped afterwards and nothing on disk is changed.

    Writes .\tools\_forcewin.png / .\tools\_forcewin.out
#>
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe='C:\GAMES\HEDZ\Hedz.exe'
$dir=Split-Path $exe -Parent
$png=Join-Path $PSScriptRoot '_forcewin.png'
$out=Join-Path $PSScriptRoot '_forcewin.out'
$targetW=640; $targetH=480

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W7 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public const uint SWP_NOZORDER=0x0004, SWP_NOACTIVATE=0x0010, SWP_SHOWWINDOW=0x0040;
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
}
'@

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }

$script:m=New-Object System.Collections.ArrayList
$script:tp=0
$cb=[W7+EnumProc]{ param($h,$l)
  $o=0; [void][W7]::GetWindowThreadProcessId($h,[ref]$o)
  if($o -eq $script:tp){
    $r=New-Object W7+R; [void][W7]::GetWindowRect($h,[ref]$r)
    [void]$script:m.Add([pscustomobject]@{H=$h;Class=[W7]::Cls($h);Vis=[W7]::IsWindowVisible($h);X=$r.L;Y=$r.T;W=($r.Rt-$r.L);Hh=($r.B-$r.T)})
  }
  return $true }

$p=Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
$script:tp=$p.Id
Say ("pid {0} launched" -f $p.Id)
Say ("forcing the render window to {0}x{1} as soon as it exists" -f $targetW,$targetH)

$found=$false; $forced=0
for($i=0;$i -lt 120;$i++){          # 30 s at 4 Hz
  Start-Sleep -Milliseconds 250
  if($p.HasExited){ Say ("[{0:N1}s] PROCESS EXITED code={1}" -f (($i+1)*0.25), $p.ExitCode); break }
  $script:m.Clear(); [void][W7]::EnumWindows($cb,[IntPtr]::Zero)
  $gw=$script:m | Where-Object { $_.Vis -and $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
  if($gw){
    if(-not $found){ $found=$true; Say ("[{0:N1}s] render window found: {1}x{2} at {3},{4}" -f (($i+1)*0.25), $gw.W,$gw.Hh,$gw.X,$gw.Y) }
    if($gw.W -ne $targetW -or $gw.Hh -ne $targetH){
      [void][W7]::SetWindowPos($gw.H,[IntPtr]::Zero,0,0,$targetW,$targetH,(0x0004 -bor 0x0010))
      [void][W7]::MoveWindow($gw.H,0,0,$targetW,$targetH,$true)
      $forced++
      $r2=New-Object W7+R; [void][W7]::GetWindowRect($gw.H,[ref]$r2)
      Say ("[{0:N1}s] forced -> now {1}x{2}  (attempt {3})" -f (($i+1)*0.25), ($r2.Rt-$r2.L),($r2.B-$r2.T),$forced)
    }
  }
}

# sample whatever is on screen now
if($found){
  Start-Sleep -Milliseconds 800
  $b=New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width,[System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
  $g=[System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen(0,0,0,0,$b.Size); $g.Dispose()
  $b.Save($png,[System.Drawing.Imaging.ImageFormat]::Png); 
  $t=0;$blk=0;$cols=@{}
  for($py=0;$py -lt 480;$py+=4){ for($px=0;$px -lt 640;$px+=4){
    $c=$b.GetPixel($px,$py); $t++
    if($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16){$blk++}
    $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
    if($cols.ContainsKey($k)){$cols[$k]++}else{$cols[$k]=1} } }
  $b.Dispose()
  Say ''
  Say ("640x480 region after forcing: {0}px, near-black {1}%, distinct colours {2}" -f $t,[Math]::Round(100*$blk/$t,1),$cols.Count)
  $cols.GetEnumerator()|Sort-Object -Property Value -Descending|Select-Object -First 8|ForEach-Object{
    Say ("   #{0} {1}%" -f $_.Key,[Math]::Round(100*$_.Value/$t,1)) }
  Say ("screenshot: {0}" -f $png)
  if(-not $p.HasExited){ Say ("process still alive after the experiment - forcing the size kept it running" ) }
}
if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Say 'stopped' }
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
