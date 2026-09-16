param(
    [string]$Png = "$PSScriptRoot\_loadout-ab\base.png",
    [int]$WX = 50, [int]$WY = 50, [int]$WW = 800, [int]$WH = 600
)
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap($Png)

function Region([double]$fx,[double]$fy,[double]$fw,[double]$fh,[string]$label){
    $x = $WX + [int]($WW*$fx); $y = $WY + [int]($WH*$fy)
    $w = [int]($WW*$fw);       $h = [int]($WH*$fh)
    $t=0;$white=0;$dark=0;$colors=@{}
    for($py=$y; $py -lt ($y+$h); $py+=3){
        for($px=$x; $px -lt ($x+$w); $px+=3){
            $c=$bmp.GetPixel($px,$py); $t++
            if($c.R -ge 200 -and $c.G -ge 200 -and $c.B -ge 200){$white++}
            if($c.R -lt 24 -and $c.G -lt 24 -and $c.B -lt 24){$dark++}
            $k='{0:X2}{1:X2}{2:X2}' -f $c.R,$c.G,$c.B
            if($colors.ContainsKey($k)){$colors[$k]++}else{$colors[$k]=1}
        }
    }
    $top = ($colors.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 |
        ForEach-Object { '#{0} {1}%' -f $_.Key, [math]::Round(100*$_.Value/$t,1) }) -join '  '
    '{0,-22} white {1,5}%  dark {2,5}%  colors {3,4}   {4}' -f $label, [math]::Round(100*$white/$t,1), [math]::Round(100*$dark/$t,1), $colors.Count, $top
}

Write-Host ("image: {0}  window: {1},{2} {3}x{4}" -f (Split-Path $Png -Leaf), $WX,$WY,$WW,$WH)
Region 0.0 0.0 1.0 1.0 'whole window'
Region 0.60 0.75 0.40 0.25 'HUD bottom-right'
Region 0.30 0.35 0.40 0.35 'screen centre'
$bmp.Dispose()
