param([string]$A = "$PSScriptRoot\_loadout-ab\base.png", [string]$B = "$PSScriptRoot\_loadout-ab\forceshel.png")
Add-Type -AssemblyName System.Drawing

function Measure-Pixelation([string]$png){
    $bmp = New-Object System.Drawing.Bitmap($png)
    # window content at 50,50 800x600
    $x0=50; $y0=50; $x1=850; $y1=650
    $pairs=0; $equal=0; $runs = New-Object System.Collections.Generic.List[int]
    $cur=1
    for($y=$y0; $y -lt $y1; $y+=8){
        $prev = $bmp.GetPixel($x0,$y)
        for($x=$x0+1; $x -lt $x1; $x++){
            $c = $bmp.GetPixel($x,$y)
            $pairs++
            if(($c.R -eq $prev.R) -and ($c.G -eq $prev.G) -and ($c.B -eq $prev.B)){
                $equal++; $cur++
            } else {
                if($cur -gt 1){ $runs.Add($cur) }
                $cur=1
            }
            $prev = $c
        }
    }
    $bmp.Dispose()
    $sorted = $runs | Sort-Object
    $med = if($sorted.Count){ $sorted[[int](($sorted.Count-1)/2)] } else { 0 }
    [pscustomobject]@{
        File = Split-Path $png -Leaf
        FlatPairPct = [math]::Round(100.0*$equal/$pairs,1)
        MedianRun   = $med
        LongRunsGt4 = @($runs | Where-Object { $_ -gt 4 }).Count
    }
}

'Measuring flat-run pixel structure (blocky images => many equal adjacent pairs, long runs)'
Measure-Pixelation $A | Format-Table -AutoSize
Measure-Pixelation $B | Format-Table -AutoSize
