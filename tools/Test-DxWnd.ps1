<#
.SYNOPSIS
    Test-DxWnd.ps1 - runs HEDZ under DxWnd with the official profile and measures
    whether it renders instead of showing a black desktop-sized window.

.DESCRIPTION
    Baseline without DxWnd (measured): a 1920x1080 window containing exactly one
    colour (pure black), covering the game's own menu dialog, then a clean exit
    (code 0) about 9 s later.

    This starts the DxWnd server in the tray, hands it the official H.E.D.Z.
    profile with /Y:<file>, and records:
      * every top-level window of both DxWnd and the game, with sizes
      * the pixel content of the game's render window (blackness / colour count)
      * how long the process lives
    A screenshot is written to tools\_dxwnd.png for eyeballing.

.PARAMETER KeepPalDdraw
    By default pal-ddraw is disabled for the run so DxWnd is the only
    authoritative DirectDraw layer. Pass this to leave it enabled.

.NOTES
    Writes .\tools\_dxwnd.out / .\tools\_dxwnd.png
#>
param(
    [int]$ObserveSeconds = 45,
    [switch]$KeepPalDdraw
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$kit   = $PSScriptRoot
$rt    = Join-Path $kit 'dxwnd\runtime'
$exe   = Join-Path $rt 'dxwnd.exe'
$prof  = Join-Path $kit 'dxwnd\HEDZ.dxw'
$game  = 'C:\GAMES\HEDZ\Hedz.exe'
$gdir  = Split-Path $game -Parent
$pdd   = Join-Path $gdir 'DDRAW.dll'
$pddOff= Join-Path $gdir 'DDRAW.dll.pal-ddraw-disabled'
$out   = Join-Path $kit '_dxwnd.out'
$png   = Join-Path $kit '_dxwnd.png'

if(-not (Test-Path $exe)){ throw "DxWnd not deployed - run tools\Install-DxWnd.ps1 first" }
if(-not (Test-Path $prof)){ throw "profile missing - run tools\Install-DxWnd.ps1 first" }

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W9 {
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
  public static bool Mine(IntPtr h, int[] pids){ uint o=0; GetWindowThreadProcessId(h, out o); foreach(var p in pids){ if(o==p) return true; } return false; }
}
'@

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }

$script:m=New-Object System.Collections.ArrayList
$script:pids=@()
$cb=[W9+EnumProc]{ param($h,$l)
  if([W9]::Mine($h,$script:pids)){
    $r=New-Object W9+R; [void][W9]::GetWindowRect($h,[ref]$r)
    [void]$script:m.Add([pscustomobject]@{H=$h;Class=[W9]::Cls($h);Title=[W9]::Txt($h);Vis=[W9]::IsWindowVisible($h);X=$r.L;Y=$r.T;W=($r.Rt-$r.L);Hh=($r.B-$r.T)})
  }
  return $true }

$restorePal = $false
try {
  if(-not $KeepPalDdraw -and (Test-Path $pdd)){
    if(Test-Path $pddOff){ Remove-Item $pddOff -Force }
    Move-Item $pdd $pddOff -Force
    $restorePal = $true
    Say 'pal-ddraw disabled for this run (DDRAW.dll -> DDRAW.dll.pal-ddraw-disabled)'
  }
  Say ''

  # ---- DxWnd server ----
  Say 'starting DxWnd server (/T /Q)...'
  Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
  Start-Sleep -Milliseconds 800
  $server = Start-Process -FilePath $exe -ArgumentList '/T','/Q' -WorkingDirectory $rt -PassThru
  Start-Sleep -Seconds 4
  if($server.HasExited){ Say ("  server exited immediately, code {0}" -f $server.ExitCode) }
  else { Say ("  server pid {0}" -f $server.Id) }

  # ---- client: load + run the profile ----
  Say ("sending /Y:`"{0}`" ..." -f $prof)
  $client = Start-Process -FilePath $exe -ArgumentList ('/Y:"' + $prof + '"') -WorkingDirectory $rt -PassThru
  $client.WaitForExit(15000) | Out-Null
  Say ("  client returned, code {0}" -f $(if($client.HasExited){$client.ExitCode}else{'still running'}))

  # ---- observe ----
  $bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
  Say ''
  Say ("observing for {0}s at 4 Hz" -f $ObserveSeconds)
  $prev=''
  $shot=$false
  $gameSizes=@()
  for($i=0;$i -lt ($ObserveSeconds*4);$i++){
    Start-Sleep -Milliseconds 250
    $he=Get-Process -Name Hedz -ErrorAction SilentlyContinue
    $dx=Get-Process -Name dxwnd -ErrorAction SilentlyContinue
    $script:pids=@()
    foreach($p in @($he)+@($dx)){ if($p){ $script:pids += $p.Id } }
    if($script:pids.Count -eq 0){ Say ("[{0:N1}s] no Hedz/dxwnd processes" -f ($i+1)*0.25); break }

    $script:m.Clear(); [void][W9]::EnumWindows($cb,[IntPtr]::Zero)
    $vis=$script:m | Where-Object { $_.Vis }
    $sig=($vis | ForEach-Object { "$($_.Class)|$($_.Title)|$($_.W)x$($_.Hh)" } | Sort-Object) -join ' ;; '
    if($sig -ne $prev){
      Say ("[{0:N1}s] window change ({1} visible):" -f (($i+1)*0.25),(@($vis).Count))
      foreach($w in $vis){ Say ("      class='{0}' title='{1}' {2},{3} {4}x{5}" -f $w.Class,$w.Title,$w.X,$w.Y,$w.W,$w.Hh) }
      $prev=$sig
      $gw=$vis | Where-Object { $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
      if($gw -and -not $shot){
        $shot=$true
        Start-Sleep -Milliseconds 1500
        $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
        $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen(0,0,0,0,$bmp.Size); $g.Dispose()
        $bmp.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
        $x=[Math]::Max(0,$gw.X); $y=[Math]::Max(0,$gw.Y)
        $x2=[Math]::Min($bounds.Width,$x+$gw.W); $y2=[Math]::Min($bounds.Height,$y+$gw.Hh)
        $t=0;$blk=0;$cols=@{}
        for($py=$y;$py -lt $y2;$py+=6){ for($px=$x;$px -lt $x2;$px+=6){
          $c=$bmp.GetPixel($px,$py); $t++
          if($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16){$blk++}
          $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
          if($cols.ContainsKey($k)){$cols[$k]++}else{$cols[$k]=1} } }
        $bmp.Dispose()
        $pct=if($t){[Math]::Round(100*$blk/$t,1)}else{0}
        Say ("      RENDER WINDOW PIXELS: {0}px, near-black {1}%, distinct colours {2}" -f $t,$pct,$cols.Count)
        if($pct -lt 90){ Say '      *** NON-BLACK - the game is rendering! ***' }
        Say ("      screenshot: {0}" -f $png)
        Say ("      foreground class: '{0}'" -f [W9]::Cls([W9]::GetForegroundWindow()))
      }
      $g2=$vis | Where-Object { $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
      if($g2){ $gameSizes += ("{0}x{1}" -f $g2.W,$g2.Hh) }
    }
    if(-not (Get-Process -Name Hedz -ErrorAction SilentlyContinue)){
      Say ("[{0:N1}s] Hedz.exe is gone" -f ($i+1)*0.25); break
    }
  }

  Say ''
  $hp=Get-Process -Name Hedz -ErrorAction SilentlyContinue
  if($hp){ Say 'Hedz.exe STILL RUNNING at the end of observation (it normally bails in ~9-25s)'; $hp | ForEach-Object { $_.Kill() } }
  else { Say 'Hedz.exe has exited (see the timings above)' }
} finally {
  Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
  Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
  if($restorePal -and (Test-Path $pddOff)){ Move-Item $pddOff $pdd -Force; Say ''; Say 'pal-ddraw restored (DDRAW.dll back in place)' }
}
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
