<#
.SYNOPSIS
    Test-DisplayModes.ps1 - finds which FullScreen / ResMode combination makes
    HEDZ create a correctly-sized, non-black render window.

.DESCRIPTION
    Established by capture: the game currently opens a window the size of the
    DESKTOP (1920x1080), fills it with pure #000000 (1 distinct colour), and
    exits with code 0 about 9 s later. Its own diagnostic strings name that
    exact condition:

        To run this program in a window of this size, please adjust your
        display settings for a smaller desktop area or a lower palette size
        and restart the program.

    The game stores its display preference in its own registry key as
    FullScreen and ResMode (both currently 0). This sweeps the plausible values,
    launches the game for each, records the window size / blackness, and puts the
    original values back.

.NOTES
    Writes HKLM (32-bit view) -> must run elevated.
    The game window will flash on screen once per combination (~10 s each).
#>
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe='C:\GAMES\HEDZ\Hedz.exe'
$dir=Split-Path $exe -Parent
$key32='HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
$key64='HKLM:\SOFTWARE\Vis Interactive\Hedz'
$out=Join-Path $PSScriptRoot '_modes.out'

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W5 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
}
'@

$script:m=New-Object System.Collections.ArrayList
$script:tp=0
$cb=[W5+EnumProc]{ param($h,$l)
  $o=0; [void][W5]::GetWindowThreadProcessId($h,[ref]$o)
  if($o -eq $script:tp){
    $r=New-Object W5+R; [void][W5]::GetWindowRect($h,[ref]$r)
    [void]$script:m.Add([pscustomobject]@{Class=[W5]::Cls($h);Vis=[W5]::IsWindowVisible($h);X=$r.L;Y=$r.T;W=($r.Rt-$r.L);Hh=($r.B-$r.T)})
  }
  return $true }

# remember originals
$origFS  = (Get-ItemProperty $key32 -Name FullScreen -ErrorAction SilentlyContinue).FullScreen
$origRes = (Get-ItemProperty $key32 -Name ResMode    -ErrorAction SilentlyContinue).ResMode

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }
Say ("originals: FullScreen={0} ResMode={1}" -f $origFS,$origRes)
Say ''

$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
$combos = @(
  @{FS=1;Res=0}, @{FS=1;Res=1}, @{FS=1;Res=2}, @{FS=1;Res=3},
  @{FS=0;Res=1}, @{FS=0;Res=2}, @{FS=0;Res=3}
)

foreach($c in $combos){
  foreach($k in $key32,$key64){
    if(Test-Path $k){
      New-ItemProperty -Path $k -Name FullScreen -Value $c.FS -PropertyType DWord -Force | Out-Null
      New-ItemProperty -Path $k -Name ResMode    -Value $c.Res -PropertyType DWord -Force | Out-Null
    }
  }
  $p=Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
  $script:tp=$p.Id
  $seen=$null; $elapsed=0
  for($i=0;$i -lt 60;$i++){
    Start-Sleep -Milliseconds 250
    $elapsed=($i+1)*0.25
    if($p.HasExited){ break }
    $script:m.Clear(); [void][W5]::EnumWindows($cb,[IntPtr]::Zero)
    $g=$script:m | Where-Object { $_.Vis -and $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
    if($g){ $seen=$g; break }
  }
  if($seen){
    Start-Sleep -Milliseconds 1500
    $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $gr=[System.Drawing.Graphics]::FromImage($bmp)
    $gr.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size); $gr.Dispose()
    $x=[Math]::Max(0,$seen.X); $y=[Math]::Max(0,$seen.Y)
    $x2=[Math]::Min($bounds.Width,$x+$seen.W); $y2=[Math]::Min($bounds.Height,$y+$seen.Hh)
    $t=0;$blk=0;$cols=@{}
    for($py=$y;$py -lt $y2;$py+=8){ for($px=$x;$px -lt $x2;$px+=8){
      $px2=$bmp.GetPixel($px,$py); $t++
      if($px2.R -lt 16 -and $px2.G -lt 16 -and $px2.B -lt 16){$blk++}
      $kk='{0:X2}{1:X2}{2:X2}' -f $px2.R,$px2.G,$px2.B
      if($cols.ContainsKey($kk)){$cols[$kk]++}else{$cols[$kk]=1} } }
    $bmp.Dispose()
    $pct=if($t){[Math]::Round(100*$blk/$t,1)}else{0}
    Say ("FullScreen={0} ResMode={1} -> window {2}x{3} at {4},{5}  black={6}%  colours={7}  (after {8:N1}s)" -f `
         $c.FS,$c.Res,$seen.W,$seen.Hh,$seen.X,$seen.Y,$pct,$cols.Count,$elapsed)
    if($pct -lt 90){ Say '     ^^^ NON-BLACK: this combination renders!' }
  } else {
    Say ("FullScreen={0} ResMode={1} -> no window observed (exited={2} code={3} after {4:N1}s)" -f `
         $c.FS,$c.Res,$p.HasExited,$(if($p.HasExited){$p.ExitCode}else{'-'}),$elapsed)
  }
  if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
}

# restore
foreach($k in $key32,$key64){
  if(Test-Path $k){
    if($origFS  -ne $null){ New-ItemProperty -Path $k -Name FullScreen -Value $origFS  -PropertyType DWord -Force | Out-Null }
    if($origRes -ne $null){ New-ItemProperty -Path $k -Name ResMode    -Value $origRes -PropertyType DWord -Force | Out-Null }
  }
}
Say ''
Say ("restored FullScreen={0} ResMode={1}" -f $origFS,$origRes)
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
