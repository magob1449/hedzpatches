<#
.SYNOPSIS
    Test-PalDdrawConfig.ps1 - does pal-ddraw's own config change anything?

.DESCRIPTION
    pal-ddraw is deployed in the game folder but had NO ddraw.ini, so it runs on
    built-in defaults. With pal-ddraw stood down entirely the game behaves
    identically, so it is currently doing nothing for this title.

    Its real keys (read out of the DLL's string table) are NoBuffer, UseFlip,
    UseThrottle and BPP. HEDZ asks for a 16-bit display mode, so BPP is the one
    that could plausibly matter.

    This writes a candidate ddraw.ini, launches the game, records window size and
    blackness, and cleans up afterwards. Two ini shapes are tried because
    pal-ddraw parses the file itself rather than via the profile API.

    Writes .\tools\_palcfg.out
#>
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe='C:\GAMES\HEDZ\Hedz.exe'
$dir=Split-Path $exe -Parent
$ini=Join-Path $dir 'ddraw.ini'
$out=Join-Path $PSScriptRoot '_palcfg.out'

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W8 {
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
$cb=[W8+EnumProc]{ param($h,$l)
  $o=0; [void][W8]::GetWindowThreadProcessId($h,[ref]$o)
  if($o -eq $script:tp){
    $r=New-Object W8+R; [void][W8]::GetWindowRect($h,[ref]$r)
    [void]$script:m.Add([pscustomobject]@{Class=[W8]::Cls($h);Vis=[W8]::IsWindowVisible($h);X=$r.L;Y=$r.T;W=($r.Rt-$r.L);Hh=($r.B-$r.T)})
  }
  return $true }

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }

$variants = @(
  @{ Name='no ini (current baseline)'; Text=$null },
  @{ Name='[PAL-DDRAW] BPP=16';        Text="[PAL-DDRAW]`r`nBPP=16`r`n" },
  @{ Name='BPP=16 (no section)';       Text="BPP=16`r`n" },
  @{ Name='[PAL-DDRAW] BPP=16 UseFlip=1'; Text="[PAL-DDRAW]`r`nBPP=16`r`nUseFlip=1`r`n" },
  @{ Name='[PAL-DDRAW] BPP=16 NoBuffer=0 UseFlip=1 UseThrottle=1'; Text="[PAL-DDRAW]`r`nBPP=16`r`nNoBuffer=0`r`nUseFlip=1`r`nUseThrottle=1`r`n" }
)

$bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen

foreach($v in $variants){
  if($v.Text -eq $null){ if(Test-Path $ini){ Remove-Item $ini -Force } }
  else { [IO.File]::WriteAllText($ini, $v.Text) }

  $p=Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
  $script:tp=$p.Id
  $seen=$null; $elapsed=0; $exitCode='-'
  for($i=0;$i -lt 60;$i++){
    Start-Sleep -Milliseconds 250
    $elapsed=($i+1)*0.25
    if($p.HasExited){ $exitCode=$p.ExitCode; break }
    $script:m.Clear(); [void][W8]::EnumWindows($cb,[IntPtr]::Zero)
    $g=$script:m | Where-Object { $_.Vis -and $_.Class -eq 'Vis Interactive' } | Select-Object -First 1
    if($g){ $seen=$g; break }
  }
  if($seen){
    Start-Sleep -Milliseconds 1500
    if($p.HasExited){ $exitCode=$p.ExitCode } else { $exitCode='alive' }
    $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $gr=[System.Drawing.Graphics]::FromImage($bmp)
    $gr.CopyFromScreen(0,0,0,0,$bmp.Size); $gr.Dispose()
    $x=[Math]::Max(0,$seen.X); $y=[Math]::Max(0,$seen.Y)
    $x2=[Math]::Min($bounds.Width,$x+$seen.W); $y2=[Math]::Min($bounds.Height,$y+$seen.Hh)
    $t=0;$blk=0;$cols=@{}
    for($py=$y;$py -lt $y2;$py+=8){ for($px=$x;$px -lt $x2;$px+=8){
      $c=$bmp.GetPixel($px,$py); $t++
      if($c.R -lt 16 -and $c.G -lt 16 -and $c.B -lt 16){$blk++}
      $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
      if($cols.ContainsKey($k)){$cols[$k]++}else{$cols[$k]=1} } }
    $bmp.Dispose()
    $pct=if($t){[Math]::Round(100*$blk/$t,1)}else{0}
    Say ("{0,-52} -> window {1}x{2}  black={3}%  colours={4}  found@{5:N1}s exit={6}" -f $v.Name,$seen.W,$seen.Hh,$pct,$cols.Count,$elapsed,$exitCode)
    if($pct -lt 95){ Say '      ^^^ NON-BLACK: this configuration renders!' }
  } else {
    Say ("{0,-52} -> no window (exit={1} after {2:N1}s)" -f $v.Name,$exitCode,$elapsed)
  }
  if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 400
}
if(Test-Path $ini){ Remove-Item $ini -Force; Say ''; Say 'ddraw.ini removed (game folder left as it was found)' }
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
