<#
.SYNOPSIS
    Watch-HedzWindows.ps1 - logs HEDZ's window lifecycle, second by second.

    Fixes the scope bug in the first attempt: variables assigned inside an
    EnumWindows callback do NOT escape to the caller's scope unless they are
    explicitly $script:-scoped, which is why the earlier window list came back
    empty even though a dialog demonstrably existed.

    Also reports, for each visible window, whether its client area is actually
    black - which is the difference between "the surface is not being presented"
    and "the surface is presenting fine".

    Writes .\tools\_win.out. Starts the game, observes, stops it.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$exe = 'C:\GAMES\HEDZ\Hedz.exe'
$dir = Split-Path $exe -Parent
$out = Join-Path $PSScriptRoot '_win.out'

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W2 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  public static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }
  public static string Txt(IntPtr h){ var sb=new StringBuilder(512); GetWindowText(h,sb,512); return sb.ToString(); }
  public static void Click(IntPtr h){ SendMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); } // BM_CLICK
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }

# $script: scope is the whole point of this rewrite
$script:found = New-Object System.Collections.ArrayList
$script:wantPid = 0

$cb = [W2+EnumProc]{
    param($h,$l)
    $op = 0
    [void][W2]::GetWindowThreadProcessId($h, [ref]$op)
    if ($op -eq $script:wantPid) {
        $r = New-Object W2+R; [void][W2]::GetWindowRect($h, [ref]$r)
        $c = New-Object W2+R; [void][W2]::GetClientRect($h, [ref]$c)
        $kids = New-Object System.Collections.ArrayList
        $kcb = [W2+EnumProc]{
            param($kh,$kl)
            [void]$kids.Add(("{0}|{1}" -f [W2]::Cls($kh), [W2]::Txt($kh)))
            return $true
        }
        [void][W2]::EnumChildWindows($h, $kcb, [IntPtr]::Zero)
        [void]$script:found.Add([pscustomobject]@{
            H     = $h
            Class = [W2]::Cls($h)
            Title = [W2]::Txt($h)
            Vis   = [W2]::IsWindowVisible($h)
            X     = $r.L; Y = $r.T; W = ($r.Rt - $r.L); Hh = ($r.B - $r.T)
            CW    = ($c.Rt - $c.L); CH = ($c.B - $c.T)
            Kids  = $kids
        })
    }
    return $true
}

Say '=== HEDZ window lifecycle (1 Hz, 30 s) ==='
$p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
$script:wantPid = $p.Id
Say ("pid {0} launched at {1:HH:mm:ss}" -f $p.Id, (Get-Date))

$prevSig = ''
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 1
    if ($p.HasExited) { Say ("[{0,2}s] PROCESS EXITED  code={1}" -f $i, $p.ExitCode); break }
    $script:found.Clear()
    [void][W2]::EnumWindows($cb, [IntPtr]::Zero)
    $vis = $script:found | Where-Object { $_.Vis }
    $sig = ($vis | ForEach-Object { "$($_.Class):$($_.Title):$($_.W)x$($_.Hh)" } | Sort-Object) -join ' ; '
    if ($sig -ne $prevSig) {
        Say ("[{0,2}s] --- change --- ({1} visible windows)" -f $i, @($vis).Count)
        foreach ($w in $vis) {
            Say ("        class='{0}' title='{1}' pos={2},{3} size={4}x{5} client={6}x{7}" -f `
                 $w.Class,$w.Title,$w.X,$w.Y,$w.W,$w.Hh,$w.CW,$w.CH)
            if (@($w.Kids).Count -gt 0) {
                $w.Kids | ForEach-Object { Say ("            child: {0}" -f $_) }
            }
        }
        $prevSig = $sig
    }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Say '  (stopped)' }

[IO.File]::WriteAllLines($out, $lines)
Write-Host ''
Write-Host ("report: {0}" -f $out)
