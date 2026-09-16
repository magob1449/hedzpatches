<#
.SYNOPSIS
    Test-NoWrapper.ps1 - runs HEDZ with the local pal-ddraw disabled so the system
    ddraw.dll is used, and reads whatever dialog the game puts up.

.DESCRIPTION
    The game currently opens a black 1920x1080 window and exits with code 0.
    Sweeping FullScreen/ResMode changed nothing, so the next variable is the
    DirectDraw provider itself.

    With pal-ddraw stood down, the real Windows DirectDraw is in charge, which
    cannot provide a 16-bit display mode. If that produces a visible error dialog,
    its text names the failure - which is the whole object of the exercise.

    The DLL is renamed, not deleted, and always restored (including on Ctrl-C
    via try/finally).

    Writes .\tools\_nowrap.out and .\tools\_nowrap.png
#>
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe='C:\GAMES\HEDZ\Hedz.exe'
$dir=Split-Path $exe -Parent
$dll=Join-Path $dir 'DDRAW.dll'
$off=Join-Path $dir 'DDRAW.dll.disabled'
$out=Join-Path $PSScriptRoot '_nowrap.out'
$png=Join-Path $PSScriptRoot '_nowrap.png'

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class W6 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
  public static string Txt(IntPtr h){ var sb=new StringBuilder(1024); GetWindowText(h,sb,1024); return sb.ToString(); }
}
'@

$lines=New-Object System.Collections.Generic.List[string]
function Say([string]$s){ $lines.Add($s); Write-Host $s }

if(-not (Test-Path $dll)){ throw "no local ddraw.dll at $dll - nothing to test" }
Say ("pal-ddraw present: {0} ({1} bytes)" -f $dll,(Get-Item $dll).Length)

$script:m=New-Object System.Collections.ArrayList
$script:tp=0
$cb=[W6+EnumProc]{ param($h,$l)
  $o=0; [void][W6]::GetWindowThreadProcessId($h,[ref]$o)
  if($o -eq $script:tp){
    $r=New-Object W6+R; [void][W6]::GetWindowRect($h,[ref]$r)
    $kids=New-Object System.Collections.ArrayList
    $kcb=[W6+EnumProc]{ param($kh,$kl)
      $txt=[W6]::Txt($kh)
      if($txt){ [void]$kids.Add(("{0}: {1}" -f [W6]::Cls($kh),$txt)) }
      return $true }
    [void][W6]::EnumChildWindows($h,$kcb,[IntPtr]::Zero)
    [void]$script:m.Add([pscustomobject]@{
      Class=[W6]::Cls($h); Title=[W6]::Txt($h); Vis=[W6]::IsWindowVisible($h)
      X=$r.L; Y=$r.T; W=($r.Rt-$r.L); Hh=($r.B-$r.T); Kids=$kids })
  }
  return $true }

try {
  Move-Item $dll $off -Force
  Say 'pal-ddraw disabled (renamed) - system ddraw.dll will be used'
  Say ''
  $p=Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
  $script:tp=$p.Id
  Say ("pid {0}" -f $p.Id)
  $prev=''
  for($i=0;$i -lt 100;$i++){
    Start-Sleep -Milliseconds 250
    if($p.HasExited){ Say ("[{0:N1}s] PROCESS EXITED code={1}" -f (($i+1)*0.25), $p.ExitCode); break }
    $script:m.Clear(); [void][W6]::EnumWindows($cb,[IntPtr]::Zero)
    $vis=$script:m | Where-Object { $_.Vis }
    $sig=($vis | ForEach-Object { "$($_.Class)|$($_.Title)|$($_.W)x$($_.Hh)|$($_.Kids -join '~')" } | Sort-Object) -join ' ;; '
    if($sig -ne $prev){
      Say ("[{0:N1}s] window change ({1} visible):" -f (($i+1)*0.25), (@($vis).Count))
      foreach($w in $vis){
        Say ("     class='{0}' title='{1}' {2},{3} {4}x{5}" -f $w.Class,$w.Title,$w.X,$w.Y,$w.W,$w.Hh)
        foreach($k in $w.Kids){ Say ("        child -> {0}" -f $k) }
      }
      if($vis | Where-Object { $_.Class -eq '#32770' }){
        Say '     >>> A DIALOG IS UP - capturing it'
        $b=New-Object System.Drawing.Bitmap([System.Windows.Forms.SystemInformation]::VirtualScreen.Width,[System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
        $g=[System.Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen(0,0,0,0,$b.Size); $g.Dispose()
        $b.Save($png,[System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
        Say ("     screenshot: {0}" -f $png)
      }
      $prev=$sig
    }
  }
  if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Say 'stopped' }
}
finally {
  if(Test-Path $off){ Move-Item $off $dll -Force; Say ''; Say 'pal-ddraw RESTORED' }
}
[IO.File]::WriteAllLines($out,$lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
