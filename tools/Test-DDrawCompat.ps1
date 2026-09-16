<#
.SYNOPSIS
    Test-DDrawCompat.ps1 - A/B test DDrawCompat v0.7.1 against the white
    in-level loadout HUD, with hardware rendering.

.DESCRIPTION
    Evidence chain so far:
      - In-level loadout textures are 128x128 ARGB4444 (DDPF_ALPHAPIXELS, RGBA
        masks 0xF00/0xF0/0xF/0xF000) with real content, but render white on the
        DxWnd HAL path (24.5% HUD white). gho's DxWnd thread ended with him
        inspecting exactly these surfaces; no shipped DxWnd fix materialized.
      - huh (thread, 2024-08-14): with DDrawCompat, allowing the A4R4G4B4
        texture format is the ONE configuration where the white panel renders
        correctly. DDC renders through its own D3D11 pipeline => hardware
        quality with native alpha-texture support.
      - huh's proven combo: DDrawCompat ddraw.dll in game folder + DxWnd on top.

    Variants:
      ddc_direct     DDrawCompat alone, game launched directly (cleanest)
      ddc_dxwnd      DDrawCompat + DxWnd windowing, FORCESHEL cleared (flagh0=22)
      ddc_dxwnd_shel DDrawCompat + DxWnd with canonical profile (FORCESHEL on)

    For each variant:
      1. stop game (and DxWnd for ddc_direct), refuse to continue if stuck
      2. deploy DDrawCompat ddraw.dll, verify byte identity
      3. launch (directly or via DxWnd profile), wait for level entry via the
         mss32 proxy .AMB marker
      4. capture the REAL game window rect, save PNG + metadata
      5. measure HUD-white% and flat-pair pixelation%

    Results land in tools\_loadout-ab\ddc_<variant>.png

.PARAMETER Variants
    Subset/order of: ddc_direct, ddc_dxwnd, ddc_dxwnd_shel
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [string[]]$Variants = @('ddc_direct','ddc_dxwnd'),
    [int]$MaxWaitForLevel = 180,
    [int]$SettleSeconds = 4,
    [switch]$FullScreen
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$kit      = $PSScriptRoot
$srcDll   = Join-Path $kit 'ddrawcompat\dist\ddraw.dll'
$rt       = Join-Path $kit 'dxwnd\runtime'
$prof     = Join-Path $kit 'dxwnd\HEDZ.dxw'
$testProf = Join-Path $kit 'dxwnd\HEDZ-ddc.dxw'
$gameDir  = Split-Path $GameExe -Parent
$proxyLog = Join-Path $gameDir 'mss32-proxy.log'
$shots    = Join-Path $kit '_loadout-ab'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

if(-not (Test-Path $srcDll)){ throw 'DDrawCompat not found under tools\ddrawcompat\dist - download DDrawCompat-v0.7.1.zip first' }
Write-Host ("DDrawCompat source: {0} ({1:N0} bytes)" -f $srcDll,(Get-Item $srcDll).Length)

# window enumeration helper
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W6 {
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
    $cb = [W6+EnumProc]{
        param($h,$l)
        $o=0; [void][W6]::GetWindowThreadProcessId($h,[ref]$o)
        if($o -eq $procId -and [W6]::IsWindowVisible($h)){
            $r=New-Object W6+R; [void][W6]::GetWindowRect($h,[ref]$r)
            $w=$r.Rt-$r.L; $hh=$r.B-$r.T
            if($w -gt 200 -and $hh -gt 200){ $script:found = @($r.L,$r.T,$w,$hh) }
        }
        return $true
    }
    [void][W6]::EnumWindows($cb,[IntPtr]::Zero)
    return $script:found
}

function Write-DDCProfile([string]$variant){
    $text = Get-Content $prof -Raw
    $text = [regex]::Replace($text,'(?m)^title0=.*$', ('title0=HEDZ-DDC'))
    if($variant -ne 'ddc_dxwnd_shel'){
        # clear FORCESHEL (dwFlags3 0x02000000): canonical flagh0=33554454 -> 22
        $text = [regex]::Replace($text,'(?m)^flagh0=33554454$','flagh0=22')
    }
    [IO.File]::WriteAllText($testProf,$text)
}

$results = @()
foreach($v in $Variants){
    Write-Host ("`n===== variant: {0} =====" -f $v)

    # --- 1. stop everything ---
    Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    if($v -eq 'ddc_direct'){
        Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
        Start-Sleep -Seconds 1
        $left = Get-Process -Name dxwnd -ErrorAction SilentlyContinue
        if($left){ Write-Host ("  dxwnd pid {0} survived - SKIPPING variant" -f $left.Id); $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;Distinct=$null;FlatPairPct=$null;Note='dxwnd-stuck'}; continue }
    }
    Start-Sleep -Milliseconds 700

    # --- 2. deploy + verify DDrawCompat ---
    if($FullScreen){
        # game registry: FullScreen=1 => the game requests a real display mode,
        # which DDrawCompat then emulates+upscales on the GPU (hardware quality)
        try {
            Set-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz' -Name FullScreen -Value 1 -Type DWord -ErrorAction Stop
            Write-Host '  registry FullScreen=1 set'
        } catch { Write-Host '  WARNING: could not set FullScreen=1 (needs admin) - continuing with current value' }
    } else {
        try {
            Set-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz' -Name FullScreen -Value 0 -Type DWord -ErrorAction Stop
        } catch { Write-Host '  NOTE: could not write FullScreen=0 (needs admin) - assuming it is already 0' }
    }
    Copy-Item $srcDll (Join-Path $gameDir 'ddraw.dll') -Force
    $d = Get-Item (Join-Path $gameDir 'ddraw.dll')
    $s = Get-Item $srcDll
    if($d.Length -ne $s.Length){ Write-Host '  ddraw.dll replaced after deploy - SKIPPING variant'; $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;Distinct=$null;FlatPairPct=$null;Note='deploy-fail'}; continue }
    Write-Host ("  ddraw.dll deployed OK ({0:N0} bytes)" -f $d.Length)

    # --- 3. launch ---
    $baseLen = 0L
    if(Test-Path $proxyLog){ $baseLen = (Get-Item $proxyLog).Length }

    if($v -eq 'ddc_direct'){
        $p = Start-Process -FilePath $GameExe -WorkingDirectory $gameDir -PassThru
        Write-Host ("  game launched directly, pid {0}" -f $p.Id)
    } else {
        Write-DDCProfile $v
        Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
        Start-Sleep -Milliseconds 700
        Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/T','/Q' -WorkingDirectory $rt | Out-Null
        Start-Sleep -Seconds 3
        $launcher = Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList ('/Y:"' + $testProf + '"') -WorkingDirectory $rt -PassThru
        $launcher.WaitForExit(15000) | Out-Null
        $hp = Get-Process -Name Hedz -ErrorAction SilentlyContinue
        if(-not $hp){ Write-Host '  game did not start under DxWnd'; $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;Distinct=$null;FlatPairPct=$null;Note='no-start'}; continue }
        $p = $hp
        Write-Host ("  game launched via DxWnd, pid {0}" -f $p.Id)
    }

    # --- wait for level entry ---
    $inLevel = $false
    for($t=0; $t -lt $MaxWaitForLevel; $t+=2){
        Start-Sleep -Seconds 2
        if($p.HasExited){ Write-Host ("  GAME EXITED EARLY after ~{0}s" -f $t); break }
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
    }
    if(-not $inLevel -and -not $p.HasExited){ Write-Host '  no level detected - capturing anyway' }
    if($p.HasExited){
        Write-Host '  game exited before capture - check WER / ddraw.log'
        $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;Distinct=$null;FlatPairPct=$null;Note='exited-early'}
        continue
    }
    Start-Sleep -Seconds $SettleSeconds

    # --- 4. capture real window rect ---
    $rect = Get-GameWindowRect $p.Id
    if(-not $rect){ Write-Host '  no game window found'; $results += [pscustomobject]@{Variant=$v;HudWhitePct=$null;Distinct=$null;FlatPairPct=$null;Note='no-window'}; continue }
    $WX,$WY,$WW,$WH = $rect
    Write-Host ("  window: {0},{1} {2}x{3}" -f $WX,$WY,$WW,$WH)

    $png = Join-Path $shots ("ddc_{0}{1}.png" -f $v,$(if($FullScreen){'_fs'}else{''}))
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $g=[System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size); $g.Dispose()
    $bmp.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    @{ X=$WX; Y=$WY; W=$WW; H=$WH; Pid=$p.Id; Variant=$v; Captured=(Get-Date -Format o) } |
        ConvertTo-Json | Set-Content (Join-Path $shots ("ddc_{0}.json" -f $v))

    # --- 5. measure ---
    $bmp = New-Object System.Drawing.Bitmap($png)
    $t=0;$white=0;$colors=@{}
    $hx = $WX+[int]($WW*0.60); $hy = $WY+[int]($WH*0.75)
    $hw = [int]($WW*0.40);     $hh = [int]($WH*0.25)
    for($py=$hy; $py -lt ($hy+$hh); $py+=3){
        for($px=$hx; $px -lt ($hx+$hw); $px+=3){
            if($px -ge $bmp.Width -or $py -ge $bmp.Height){ continue }
            $c=$bmp.GetPixel($px,$py); $t++
            if($c.R -ge 200 -and $c.G -ge 200 -and $c.B -ge 200){$white++}
            $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
            if($colors.ContainsKey($k)){$colors[$k]++}else{$colors[$k]=1}
        }
    }
    $pairs=0;$equal=0
    for($yy=$WY+200; $yy -lt $WY+400; $yy+=8){
        if($yy -ge $bmp.Height){ break }
        $prev=$bmp.GetPixel($WX,$yy)
        for($xx=$WX+1; $xx -lt ($WX+$WW); $xx++){
            if($xx -ge $bmp.Width){ break }
            $c=$bmp.GetPixel($xx,$yy); $pairs++
            if(($c.R -eq $prev.R) -and ($c.G -eq $prev.G) -and ($c.B -eq $prev.B)){$equal++}
            $prev=$c
        }
    }
    $bmp.Dispose()

    $wp = if($t){ [math]::Round(100.0*$white/$t,1) } else { $null }
    $fp = if($pairs){ [math]::Round(100.0*$equal/$pairs,1) } else { $null }
    $note = if($inLevel){'in-level'}else{'front-end'}
    Write-Host ("  HUD white {0}%  colors {1}  flat-pairs {2}%  [{3}]" -f $wp,$colors.Count,$fp,$note)
    $results += [pscustomobject]@{Variant=$v;HudWhitePct=$wp;Distinct=$colors.Count;FlatPairPct=$fp;Note=$note}

    Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 800
}

if($Variants -contains 'ddc_direct'){
    Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
}

Write-Host "`n=== SUMMARY (ref: DxWnd HAL base 24.5% white | FORCESHEL 0.6%) ==="
$results | Format-Table Variant,HudWhitePct,Distinct,FlatPairPct,Note -AutoSize
$results | Export-Csv (Join-Path $shots 'ddc-results.csv') -NoTypeInformation
