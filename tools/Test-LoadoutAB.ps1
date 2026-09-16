<#
.SYNOPSIS
    Test-LoadoutAB.ps1 - automated A/B test of DxWnd texture flags against the
    white in-level loadout HUD.

.DESCRIPTION
    Evidence so far: in-level loadout textures are 128x128 R4G4B4A4 (alpha
    sprites) and dump with real content, while the front-end R5G6B5 textures
    render fine. Hypothesis: the official profile's USERGB565 forcing and/or
    NOALPHACHANNEL breaks rendering of alpha-textured quads in-level.

    For each variant this script:
      1. derives HEDZ-test.dxw from the official profile (bit-exact rewrites)
      2. launches DxWnd + game (mss32 proxy logging must be deployed - it is
         the level-entry detector)
      3. waits for the attract/demo mode to enter a level (proxy log opens
         Music\*.AMB), then settles 3 s
      4. captures the game window PNG and measures near-white pixel coverage
         in the bottom-right HUD region (where the white loadout ovals sit)
      5. kills the game and DxWnd, moves to the next variant

    Results land in tools\_loadout-ab\<variant>.png plus a summary table.
    Lower HUD-white% than 'base' = candidate fix. eyeball the PNGs to confirm.

.PARAMETER Variants
    Subset/order of: base, alphaon, no565, no565_alphaon, allnative, forceshel, mincaps, fs_bilinear, fs_bilinear2x
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [string[]]$Variants = @('base','alphaon','no565','no565_alphaon'),
    [int]$MaxWaitForLevel = 150
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$kit      = $PSScriptRoot
$rt       = Join-Path $kit 'dxwnd\runtime'
$dxwndExe = Join-Path $rt 'dxwnd.exe'
$prof     = Join-Path $kit 'dxwnd\HEDZ.dxw'
$test     = Join-Path $kit 'dxwnd\HEDZ-test.dxw'
$proxyLog = 'C:\GAMES\HEDZ\mss32-proxy.log'
$shots    = Join-Path $kit '_loadout-ab'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

if(-not (Test-Path $dxwndExe)){ throw 'DxWnd not deployed - run tools\Install-DxWnd.ps1' }
if(-not (Test-Path $proxyLog)){ Write-Host 'WARNING: mss32 proxy log missing - level detection will fall back to a fixed 60 s wait' }

# ---------- bit math (int64-safe) ----------
function Clear-Bits([uint32]$v,[uint32]$m){
    [uint32](([int64]$v) -band (([int64]4294967295) -bxor ([int64]$m)))
}
function Set-Bits([uint32]$v,[uint32]$m){
    [uint32]((([int64]$v) -bor ([int64]$m)) -band 4294967295)
}

# official-profile base values (log-verified flag names in comments)
$flag0 = [uint32]673185824    # MODIFYMOUSE USERGB565 CLIENTREMAPPING LOCKWINPOS ...
$flagi0= [uint32]138412036    # FIXREFCOUNTER NOPOWER2FIX NOALPHACHANNEL
$flagj0= [uint32]134222976    # AEROBOOST REMAPMCI TEXTUREFORMAT BILINEARFILTER (loadout+smooth fix)
$BILINEARFILTER = [uint32]0x00000400   # dwFlags5: bilinear stretch filtering
$BILINEAR2X     = [uint32]0x00000400   # dwFlags4: smooth low-res in emulation mode
$flagh0= [uint32]33554454     # MARKBLIT SUPPRESSD3DEXT HOOKENABLED FORCESHEL (dwFlags3, loadout fix)
$USERGB565      = [uint32]0x00200000   # dwFlags1
$NOALPHACHANNEL = [uint32]0x08000000   # dwFlags4
$FORCESHEL      = [uint32]0x02000000   # dwFlags3: DDCREATE_EMULATIONONLY
$MINIMALCAPS    = [uint32]0x00040000   # dwFlags3: simulate minimal HW caps

# ---------- per-variant flag computation ----------
function Get-VariantFlags([string]$v){
    $f0=$flag0; $fi=$flagi0; $fj=$flagj0; $fh=$flagh0
    switch($v){
        'base'          { }
        'alphaon'       { $fi = Clear-Bits $fi $NOALPHACHANNEL }
        'no565'         { $f0 = Clear-Bits $f0 $USERGB565 }
        'no565_alphaon' { $f0 = Clear-Bits $f0 $USERGB565; $fi = Clear-Bits $fi $NOALPHACHANNEL }
        'allnative'     { $f0 = Clear-Bits $f0 $USERGB565; $fi = Clear-Bits $fi $NOALPHACHANNEL; $fj = Clear-Bits $fj ([uint32]0x08000000) }
        'forceshel'     { $fh = Set-Bits $fh $FORCESHEL }
        'mincaps'       { $fh = Set-Bits $fh $MINIMALCAPS }
        'fs_bilinear'   { $fh = Set-Bits $fh $FORCESHEL; $fj = Set-Bits $fj $BILINEARFILTER }
        'fs_bilinear2x' { $fh = Set-Bits $fh $FORCESHEL; $fi = Set-Bits $fi $BILINEAR2X }
        default         { throw "unknown variant '$v'" }
    }
    [pscustomobject]@{ flag0=$f0; flagi0=$fi; flagj0=$fj; flagh0=$fh }
}

function Write-VariantProfile($f){
    $text = Get-Content $prof -Raw
    $text = [regex]::Replace($text,'(?m)^flag0=(.*)$',  ('flag0='  + $f.flag0))
    $text = [regex]::Replace($text,'(?m)^flagi0=(.*)$', ('flagi0=' + $f.flagi0))
    $text = [regex]::Replace($text,'(?m)^flagj0=(.*)$', ('flagj0=' + $f.flagj0))
    $text = [regex]::Replace($text,'(?m)^flagh0=(.*)$', ('flagh0=' + $f.flagh0))
    [IO.File]::WriteAllText($test,$text)
}

# ---------- window helpers ----------
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W4 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
}
'@

function Get-GameWindowRect([int]$procId){
    $found = $null
    $cb = [W4+EnumProc]{
        param($h,$l)
        $o=0; [void][W4]::GetWindowThreadProcessId($h,[ref]$o)
        if($o -eq $procId -and [W4]::IsWindowVisible($h)){
            $r=New-Object W4+R; [void][W4]::GetWindowRect($h,[ref]$r)
            $w=$r.Rt-$r.L; $hh=$r.B-$r.T
            if($w -gt 200 -and $hh -gt 200){
                $script:found = @($r.L,$r.T,$w,$hh)
            }
        }
        return $true
    }
    [void][W4]::EnumWindows($cb,[IntPtr]::Zero)
    return $script:found
}

function Measure-HudWhite([string]$png,[int]$x,[int]$y,[int]$w,[int]$h){
    $bmp = New-Object System.Drawing.Bitmap($png)
    try {
        # HUD region: bottom-right 40% width, bottom 25% height of the window
        $hx = $x + [int]($w*0.60); $hy = $y + [int]($h*0.75)
        $hw = [int]($w*0.40);      $hh = [int]($h*0.25)
        $t=0; $white=0; $dark=0; $colors=@{}
        for($py=$hy; $py -lt ($hy+$hh); $py+=3){
            for($px=$hx; $px -lt ($hx+$hw); $px+=3){
                $c=$bmp.GetPixel($px,$py); $t++
                if($c.R -ge 200 -and $c.G -ge 200 -and $c.B -ge 200){ $white++ }
                if($c.R -lt 24 -and $c.G -lt 24 -and $c.B -lt 24){ $dark++ }
                $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
                if($colors.ContainsKey($k)){$colors[$k]++}else{$colors[$k]=1}
            }
        }
        [pscustomobject]@{
            HudWhitePct = [math]::Round(100.0*$white/$t,1)
            HudDarkPct  = [math]::Round(100.0*$dark/$t,1)
            Distinct    = $colors.Count
        }
    } finally { $bmp.Dispose() }
}

# ---------- main loop ----------
$results = @()
foreach($v in $Variants){
    $f = Get-VariantFlags $v
    Write-VariantProfile $f
    Write-Host ("[{0}] flag0=0x{1:X8} flagh0=0x{2:X8} flagi0=0x{3:X8} flagj0=0x{4:X8}" -f $v,$f.flag0,$f.flagh0,$f.flagi0,$f.flagj0)

    Get-Process -Name Hedz,-dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 800

    $baseLen = 0L
    if(Test-Path $proxyLog){ $baseLen = (Get-Item $proxyLog).Length }

    Start-Process -FilePath $dxwndExe -ArgumentList '/T','/Q' -WorkingDirectory $rt | Out-Null
    Start-Sleep -Seconds 3
    $p = Start-Process -FilePath $dxwndExe -ArgumentList ('/Y:"' + $test + '"') -WorkingDirectory $rt -PassThru
    $p.WaitForExit(15000) | Out-Null

    $hp = Get-Process -Name Hedz -ErrorAction SilentlyContinue
    if(-not $hp){ Write-Host '  game did not start - skipping'; $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;HudDarkPct=$null;Distinct=$null;Note='no-start'}; continue }
    $hpid = $hp.Id

    $inLevel = $false
    for($t=0; $t -lt $MaxWaitForLevel; $t+=2){
        Start-Sleep -Seconds 2
        if($hp.HasExited){ break }
        if(Test-Path $proxyLog){
            $len = (Get-Item $proxyLog).Length
            if($len -gt $baseLen){
                $fs=[IO.File]::Open($proxyLog,'Open','Read','ReadWrite')
                try{
                    $fs.Seek($baseLen,'Begin') | Out-Null
                    $rd=New-Object byte[] ($len-$baseLen); [void]$fs.Read($rd,0,$rd.Length)
                    $txt=[Text.Encoding]::ASCII.GetString($rd)
                } finally { $fs.Close() }
                if($txt -match '\.AMB'){ $inLevel=$true; Write-Host ("  level entered at ~{0}s (AMB stream open)" -f ($t+2)); break }
            }
        }
        if($t -eq 58 -and -not (Test-Path $proxyLog)){ $t=$MaxWaitForLevel-6 }  # fallback: stop at ~64s
    }
    if(-not $inLevel -and -not $hp.HasExited){
        Write-Host '  never reached a level - capturing front-end instead (marked FE)'
    }
    Start-Sleep -Seconds 3

    $rect = Get-GameWindowRect $hpid
    if(-not $rect){ Write-Host '  no game window found - skipping'; $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;HudDarkPct=$null;Distinct=$null;Note='no-window'}; continue }
    $x,$y,$w,$h = $rect
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $g=[System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size); $g.Dispose()
    $png = Join-Path $shots ("{0}.png" -f $v)
    $bmp.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $m = Measure-HudWhite $png $x $y $w $h
    $note = if($inLevel){'in-level'}else{'front-end'}
    Write-Host ("  {0} window {1},{2} {3}x{4} -> HUD white {5}%  dark {6}%  colors {7}" -f $note,$x,$y,$w,$h,$m.HudWhitePct,$m.HudDarkPct,$m.Distinct)
    $results += [pscustomobject]@{Variant=$v;HudWhitePct=$m.HudWhitePct;HudDarkPct=$m.HudDarkPct;Distinct=$m.Distinct;Note=$note}
}

Get-Process -Name Hedz,-dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

Write-Host ''
Write-Host '=== SUMMARY (lower HUD-white than base = candidate fix) ==='
$results | Format-Table Variant,HudWhitePct,HudDarkPct,Distinct,Note -AutoSize
$results | Export-Csv (Join-Path $shots 'results.csv') -NoTypeInformation
Write-Host ("screenshots: {0}" -f $shots)
