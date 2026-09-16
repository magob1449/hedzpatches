$ErrorActionPreference='Stop'
$T = Join-Path $PSScriptRoot 'dxwnd\runtime\texture.out'

function Get-TexStats([string]$path){
    $b = [IO.File]::ReadAllBytes($path)
    if($b.Length -lt 124){ return $null }
    $off = [BitConverter]::ToInt32($b,10)          # bfOffBits
    $w   = [BitConverter]::ToInt32($b,18)          # biWidth (V4 header at 14)
    $h0  = [BitConverter]::ToInt32($b,22)          # biHeight (negative = top-down)
    $bpp = [BitConverter]::ToInt16($b,28)
    if($bpp -ne 16 -or $w -le 0){ return $null }
    $h   = [Math]::Abs($h0)
    $pitch = ((($w * 16) + 31) -band (-bnot 31)) / 8
    $nonzero=0; $opaque=0; $colors=@{}
    $total = 0
    for($y=0; $y -lt $h; $y+=4){
        $row = $off + $y*$pitch
        if($row+2*$w -gt $b.Length){ break }
        for($x=0; $x -lt $w; $x+=4){
            $v = [BitConverter]::ToUInt16($b, $row + 2*$x)
            $total++
            if($v -ne 0){ $nonzero++ }
            if(($v -band 0xF000) -ne 0){ $opaque++ }
            $lum = ((($v -shr 8) -band 0xF) + (($v -shr 4) -band 0xF) + ($v -band 0xF))
            $colors[$lum] = $true
        }
    }
    if($total -eq 0){ return $null }
    return [pscustomobject]@{
        File = Split-Path $path -Leaf
        Size = "$($w)x$h"
        PctNonZero = [math]::Round(100.0*$nonzero/$total,1)
        PctOpaque  = [math]::Round(100.0*$opaque/$total,1)
        LumLevels  = $colors.Count
    }
}

Write-Host '=== R4G4B4A4 (in-level) textures ==='
$alpha = Get-ChildItem $T -Filter '*R4G4B4A4*.bmp' | ForEach-Object { Get-TexStats $_.FullName }
$alpha | Group-Object Size | ForEach-Object {
    $g=$_.Group
    Write-Host ('{0}: {1} files | avg non-zero px {2}% | avg opaque {3}% | distinct-lum min/med/max: {4}/{5}/{6}' -f `
        $_.Name, $g.Count,
        [math]::Round(($g | Measure-Object PctNonZero -Average).Average,1),
        [math]::Round(($g | Measure-Object PctOpaque  -Average).Average,1),
        ($g.LumLevels | Measure-Object -Minimum).Minimum,
        ($g.LumLevels | Sort-Object)[[int](($g.Count-1)/2)],
        ($g.LumLevels | Measure-Object -Maximum).Maximum)
}
Write-Host ''
Write-Host '=== most-blank R4G4B4A4 files (candidate white-slot textures) ==='
$alpha | Sort-Object PctNonZero | Select-Object -First 8 | Format-Table File,Size,PctNonZero,PctOpaque,LumLevels -AutoSize
Write-Host '=== most-content R4G4B4A4 files ==='
$alpha | Sort-Object PctNonZero -Descending | Select-Object -First 8 | Format-Table File,Size,PctNonZero,PctOpaque,LumLevels -AutoSize

Write-Host '=== R5G6B5 128x128 comparison (if any) ==='
Get-ChildItem $T -Filter 'texture.128.128.R5G6B5*.bmp' | Select-Object -First 3 | ForEach-Object {
    $s = Get-TexStats $_.FullName
    if($s){ '{0}  non-zero {1}%  lum-levels {2}' -f $s.File,$s.PctNonZero,$s.LumLevels }
}
