<#
.SYNOPSIS
    Capture-OnWindow.ps1 - screenshots the game the instant its render window
    appears, then records what happens to that window second by second.

    Earlier captures missed because the game exits ~10-25 s after launch and the
    sampling landed after the window was gone. This polls at 4 Hz and fires the
    capture on the first visible 'Vis Interactive' window.

    Writes .\tools\_onwin.png (open this to SEE the frame) and .\tools\_onwin.out
#>
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe='C:\GAMES\HEDZ\Hedz.exe'
$dir=Split-Path $exe -Parent
$png=Join-Path $PSScriptRoot '_onwin.png'
$out=Join-Path $PSScriptRoot '_onwin.out'

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W4 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
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

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }

$script:m=New-Object System.Collections.ArrayList
$script:pid2=0
$cb=[W4+EnumProc]{ param($h,$l)
  $o=0; [void][W4]::GetWindowThreadProcessId($h,[ref]$o)
  if($o -eq $script:pid2){
    $r=New-Object W4+R; [void][W4]::GetWindowRect($h,[ref]$r)
    [void]$script:m.Add([pscustomobject]@{H=$h;Class=[W4]::Cls($h);Title=[W4]::Txt($h);Vis=[W4]::IsWindowVisible($h);X=$r.L;Y=$r.T;W=($r.Rt-$r.L);Hh=($r.B-$r.T)})
  }
  return $true }

$p=Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
$script:pid2=$p.Id
Say ("pid {0} launched {1:HH:mm:ss.fff}" -f $p.Id,(Get-Date))

$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
$captured=$false
$gameWin=$null
$t0=Get-Date
for($i=0;$i -lt 240;$i++){
  Start-Sleep -Milliseconds 250
  if($p.HasExited){ Say ("[{0:N1}s] PROCESS EXITED code={1}" -f ((Get-Date)-$t0).TotalSeconds,$p.ExitCode); break }
  $script:m.Clear(); [void][W4]::EnumWindows($cb,[IntPtr]::Zero)
  $gw=$script:m | Where-Object { $_.Vis -and $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
  if($gw -and -not $captured){
    $captured=$true
    $gameWin=$gw
    Say ("[{0:N1}s] game window APPEARED: {1},{2} {3}x{4}" -f ((Get-Date)-$t0).TotalSeconds,$gw.X,$gw.Y,$gw.W,$gw.Hh)
    Start-Sleep -Milliseconds 1200     # let it draw a frame or two
    $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $g=[System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size); $g.Dispose()
    $bmp.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
    Say ("        screenshot saved: {0}" -f $png)
    # sample the game window itself
    $x=[Math]::Max(0,$gw.X); $y=[Math]::Max(0,$gw.Y)
    $x2=[Math]::Min($bounds.Width,$x+$gw.W); $y2=[Math]::Min($bounds.Height,$y+$gw.Hh)
    $t=0;$blk=0;$cols=@{}
    for($py=$y;$py -lt $y2;$py+=6){ for($px=$x;$px -lt $x2;$px+=6){
      $c=$bmp.GetPixel($px,$py); $t++
      if($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16){$blk++}
      $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
      if($cols.ContainsKey($k)){$cols[$k]++}else{$cols[$k]=1} } }
    Say ("        GAME WINDOW PIXELS: {0}px sampled, near-black {1}%, distinct colours {2}" -f $t,[Math]::Round(100*$blk/$t,1),$cols.Count)
    $cols.GetEnumerator()|Sort-Object -Property Value -Descending|Select-Object -First 10|ForEach-Object{
      Say ("           #{0} {1}%" -f $_.Key,[Math]::Round(100*$_.Value/$t,1)) }
    $fg=[W4]::GetForegroundWindow()
    Say ("        foreground class at capture: '{0}'" -f [W4]::Cls($fg))
    $bmp.Dispose()
  }
  if($captured -and -not $gw){
    Say ("[{0:N1}s] game window GONE" -f ((Get-Date)-$t0).TotalSeconds)
    break
  }
}
if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Say 'stopped' }
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
