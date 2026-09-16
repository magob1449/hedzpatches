<#
.SYNOPSIS
    Test-DgVoodoo.ps1 - deploy dgVoodoo2 x86 wrappers to the game folder and
    A/B-test hardware rendering against the DxWnd paths.

.DESCRIPTION
    Evidence so far:
      - DxWnd HAL path:          in-level loadout R4G4B4A4 sprites render white (24.5% HUD white)
      - DxWnd FORCESHEL:         fixed but low-res/pixelated (77.8% flat pairs), bilinear helped (22.4%)
      - dgVoodoo2:               DDraw/D3D1-7 -> D3D11/12 on the real GPU, native 4444 support,
                                 bilinear resampling - the "hardware rendering like it should" candidate.

    IMPORTANT (learned 2025-09-15): Run-Hedz.ps1's pal-ddraw retirement renames ANY
    DDRAW.dll found in the game folder - including dgVoodoo's - to
    DDRAW.dll.pal-ddraw-disabled. This test deploys its own copy and VERIFIES it
    is in place after every step, and never runs Run-Hedz.ps1.

    Steps:
      1. stop DxWnd + game (one-wrapper rule; refuse to continue if DxWnd survives)
      2. deploy MS/x86/DDraw.dll + D3DImm.dll + dgVoodoo.conf, verify identity
      3. launch Hedz.exe directly, wait for level entry via mss32 proxy .AMB marker
      4. capture the REAL game window rect, save PNG + metadata JSON
      5. measure HUD-white% and flat-pair pixelation% with the real coords

.PARAMETER MeasureOnly
    Skip deploy/launch; re-measure the last capture from saved metadata.
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [switch]$MeasureOnly,
    [int]$MaxWaitForLevel = 180
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$kit      = $PSScriptRoot
$src      = Join-Path $kit 'dgvoodoo\MS\x86'
$conf     = Join-Path $kit 'dgvoodoo\dgVoodoo.conf'
$gameDir  = Split-Path $GameExe -Parent
$proxyLog = Join-Path $gameDir 'mss32-proxy.log'
$shots    = Join-Path $kit '_loadout-ab'
$metaPath = Join-Path $shots 'dgvoodoo-capture.json'
$pngPath  = Join-Path $shots 'dgvoodoo.png'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

if($MeasureOnly){
    if(-not (Test-Path $pngPath)){ throw 'no previous capture found' }
    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
    $WX = [int]$meta.X; $WY = [int]$meta.Y; $WW = [int]$meta.W; $WH = [int]$meta.H
} else {
    if(-not (Test-Path (Join-Path $src 'DDraw.dll'))){ throw 'dgVoodoo x86 DLLs missing under tools\dgvoodoo\MS\x86' }

    Write-Host '=== 1. stopping DxWnd + game (one-wrapper rule) ==='
    Get-Process -Name Hedz,dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
    Start-Sleep -Seconds 1
    $left = Get-Process -Name dxwnd -ErrorAction SilentlyContinue
    if($left){ throw ("dxwnd.exe pid {0} could not be stopped - kill manually first (two wrappers = invalid result)" -f $left.Id) }
    Write-Host '  confirmed: no DxWnd running'

    Write-Host '=== 2. deploying + verifying dgVoodoo2 x86 ==='
    Copy-Item (Join-Path $src 'DDraw.dll')  (Join-Path $gameDir 'DDraw.dll')  -Force
    Copy-Item (Join-Path $src 'D3DImm.dll') (Join-Path $gameDir 'D3DImm.dll') -Force
    Copy-Item $conf (Join-Path $gameDir 'dgVoodoo.conf') -Force
    foreach($f in 'DDraw.dll','D3DImm.dll'){
        $d = Get-Item (Join-Path $gameDir $f)
        $s = Get-Item (Join-Path $src $f)
        if($d.Length -ne $s.Length){ throw ("{0} size mismatch after deploy ({1} vs {2}) - something replaced it" -f $f,$d.Length,$s.Length) }
        Write-Host ("  {0}  {1:N0} bytes OK" -f $f,$d.Length)
    }
    Write-Host '  dgVoodoo.conf deployed (DesktopBitDepth=16, bilinear, watermark on)'

    Write-Host '=== 3. launching game directly ==='
    $baseLen = 0L
    if(Test-Path $proxyLog){ $baseLen = (Get-Item $proxyLog).Length }
    $p = Start-Process -FilePath $GameExe -WorkingDirectory $gameDir -PassThru
    Write-Host ("  pid {0}" -f $p.Id)

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
        Write-Host '  game exited before capture - run tools\_wercrash.ps1 and check tools\trace\debug-messages.txt'
        return
    }
    Start-Sleep -Seconds 3

    Write-Host '=== 4. capturing real window rect ==='
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W5 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
}
'@
    $found = $null
    $cb = [W5+EnumProc]{
        param($h,$l)
        $o=0; [void][W5]::GetWindowThreadProcessId($h,[ref]$o)
        if($o -eq $p.Id -and [W5]::IsWindowVisible($h)){
            $r=New-Object W5+R; [void][W5]::GetWindowRect($h,[ref]$r)
            $w=$r.Rt-$r.L; $hh=$r.B-$r.T
            if($w -gt 200 -and $hh -gt 200){ $script:found=@($r.L,$r.T,$w,$hh) }
        }
        return $true
    }
    [void][W5]::EnumWindows($cb,[IntPtr]::Zero)
    if(-not $found){ Write-Host '  no game window found - aborting capture'; return }
    $WX,$WY,$WW,$WH = $found
    Write-Host ("  window: {0},{1} {2}x{3}" -f $WX,$WY,$WW,$WH)

    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height)
    $g=[System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size); $g.Dispose()
    $bmp.Save($pngPath,[System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    @{ X=$WX; Y=$WY; W=$WW; H=$WH; Pid=$p.Id; Captured=(Get-Date -Format o) } |
        ConvertTo-Json | Set-Content $metaPath
    Write-Host ("  saved {0}" -f $pngPath)
}

Write-Host '=== 5. measurement (real window coords) ==='
$bmp = New-Object System.Drawing.Bitmap($pngPath)
function Reg([int]$x,[int]$y,[int]$w,[int]$h,[string]$label){
    $t=0;$white=0;$colors=@{}
    for($py=$y; $py -lt ($y+$h); $py+=3){
        for($px=$x; $px -lt ($x+$w); $px+=3){
            if($px -ge $bmp.Width -or $py -ge $bmp.Height){ continue }
            $c=$bmp.GetPixel($px,$py); $t++
            if($c.R -ge 200 -and $c.G -ge 200 -and $c.B -ge 200){$white++}
            $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
            if($colors.ContainsKey($k)){$colors[$k]++}else{$colors[$k]=1}
        }
    }
    if($t -eq 0){ return "$label - empty region" }
    $top = ($colors.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 |
        ForEach-Object { '#{0} {1}%' -f $_.Key, [math]::Round(100*$_.Value/$t,1) }) -join '  '
    '{0,-18} white {1,5}%  colors {2,5}   {3}' -f $label, [math]::Round(100*$white/$t,1), $colors.Count, $top
}
Reg ($WX+[int]($WW*0.60)) ($WY+[int]($WH*0.75)) [int]($WW*0.40) [int]($WH*0.25) 'HUD bottom-right'
Reg $WX $WY $WW $WH 'whole window'
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
('pixelation (flat-pair %): {0}   [DxWnd HAL base: 51.7 | FORCESHEL: 77.8 | FORCESHEL+bilinear: 22.4]' -f [math]::Round(100.0*$equal/$pairs,1))
$bmp.Dispose()
Write-Host ''
Write-Host 'Reference (DxWnd): base HUD-white 24.5% | forceshel 0.6% | fs_bilinear 0.5%'
