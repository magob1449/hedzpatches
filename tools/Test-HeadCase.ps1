<#
.SYNOPSIS
    Test-HeadCase.ps1 - A/B test DxWnd texture flags against the white
    heads-selection-screen bug.

.DESCRIPTION
    The heads-selection screen is rendered through Direct3D (RAMP device -
    strings hdz_FE_headcase.h / "Failed to obtain D3D surface for head case" /
    vox_head_*), while the rest of the front end is plain DirectDraw. Under the
    official DxWnd profile the heads come out pure white, which is a texture
    pixel-format failure class. This script rewrites the flag bitmasks of the
    official profile into named variants, saves tools\dxwnd\HEDZ-test.dxw, and
    launches the game under it via DxWnd /Y - exactly one variant per run.

    Variants (all derived from the official profile, changing ONLY texture bits):

      base          official profile untouched (control - known white heads)
      notexformat   clear TEXTUREFORMAT      (dwFlags5 0x08000000)
      texformatoff_565off  also clear USERGB565 (dwFlags1 0x00200000)
      alphaon       clear NOALPHACHANNEL     (dwFlags4 0x08000000)
      allnative     TEXTUREFORMAT + NOALPHACHANNEL + USERGB565 all cleared
      texdump       official profile + TEXTUREDUMP alone (every DDSCAPS_TEXTURE
                    surface unlocked in-game is written to
                    tools\dxwnd\runtime\texture.out\<w>.<h>.<fmt>.<hash>.bmp,
                    with sizes/formats logged to dxwnd.log). NOTE: do NOT
                    combine with TEXTUREHIGHLIGHT - TextureHandling()'s switch
                    then falls to default: and only Highlight runs (observed).
      trace         official profile + DxWnd ddraw/d3d trace logging on
                    (writes dxwnd.log for post-mortem analysis)

    Between variants: quit the game (or Stop-Hedz.ps1), then run the next one.
    The profile that shows real head graphics wins; its flags then go into
    tools\dxwnd\HEDZ.dxw permanently.

.PARAMETER Variant
    One of: list, base, notexformat, texformatoff_565off, alphaon, allnative, trace
#>
[CmdletBinding()]
param(
    [string]$GameExe = 'C:\GAMES\HEDZ\Hedz.exe',
    [ValidateSet('list','base','notexformat','texformatoff_565off','alphaon','allnative','texdump','trace')]
    [string]$Variant = 'list'
)
$ErrorActionPreference = 'Stop'
$kit     = $PSScriptRoot
$rt      = Join-Path $kit 'dxwnd\runtime'
$exe     = Join-Path $rt 'dxwnd.exe'
$prof    = Join-Path $kit 'dxwnd\HEDZ.dxw'
$test    = Join-Path $kit 'dxwnd\HEDZ-test.dxw'

if($Variant -eq 'list'){
    Write-Host 'variants: base | notexformat | texformatoff_565off | alphaon | allnative | texdump | trace'
    Write-Host 'usage:    powershell -File tools\Test-HeadCase.ps1 -Variant <name>'
    return
}

if(-not (Test-Path $exe))  { throw "DxWnd not deployed - run tools\Install-DxWnd.ps1" }
if(-not (Test-Path $prof)) { throw "profile missing   - run tools\Install-DxWnd.ps1" }

# ---------- bit math ----------
function Clear-Bits([uint32]$v,[uint32]$m){ return ($v -band (-bnot $m)) }
function Set-Bits  ([uint32]$v,[uint32]$m){ return ($v -bor $m) }

# base values from the official profile
$flag0  = [uint32]673185824   # dwFlags1  MODIFYMOUSE|USERGB565|CLIENTREMAPPING|LOCKWINPOS
$flagg0 = [uint32]1207959552  # dwFlags2  WINDOWIZE|SETCOMPATIBILITY
$flagh0 = [uint32]33554454    # dwFlags3  MARKBLIT|SUPPRESSD3DEXT|HOOKENABLED|FORCESHEL (loadout fix)
$flagi0 = [uint32]138412036   # dwFlags4  FIXREFCOUNTER|NOPOWER2FIX|NOALPHACHANNEL
$flagj0 = [uint32]134222976   # dwFlags5  AEROBOOST|REMAPMCI|TEXTUREFORMAT|BILINEARFILTER (loadout+smooth fix)
$flagk0 = [uint32]65536       # dwFlags6  FLIPEMULATION
$tflag0 = [uint32]0           # trace flags: 0x1 OUTTRACE 0x2 DDRAW 0x800 D3D 0x80000000 ERASELOG

$TEXTUREFORMAT = [uint32]0x08000000  # dwFlags5 "Set texture pixel format"
$USERGB565     = [uint32]0x00200000  # dwFlags1 "Use RGB565 textures"
$NOALPHACHANNEL= [uint32]0x08000000  # dwFlags4 "no DDPF_ALPHAPIXELS capability"

switch($Variant){
    'base'                 { }
    'notexformat'          { $flagj0 = Clear-Bits $flagj0 $TEXTUREFORMAT }
    'texformatoff_565off'  { $flagj0 = Clear-Bits $flagj0 $TEXTUREFORMAT; $flag0 = Clear-Bits $flag0 $USERGB565 }
    'alphaon'              { $flagi0 = Clear-Bits $flagi0 $NOALPHACHANNEL }
    'allnative'            { $flagj0 = Clear-Bits $flagj0 $TEXTUREFORMAT; $flag0 = Clear-Bits $flag0 $USERGB565; $flagi0 = Clear-Bits $flagi0 $NOALPHACHANNEL }
    'texdump'              { $flagj0 = Set-Bits $flagj0 ([uint32]0x00004000); $tflag0 = Set-Bits $tflag0 ([uint32]0x00000001) }  # TEXTUREDUMP only + OUTTRACE
    'trace'                { $tflag0 = Set-Bits $tflag0 ([uint32]0x00000803) }  # OUTTRACE|DDRAWTRACE|D3DTRACE
}

# ---------- write variant profile ----------
$text = Get-Content $prof -Raw
$text = [regex]::Replace($text,'(?m)^flag0=(.*)$',  ('flag0='  + $flag0))
$text = [regex]::Replace($text,'(?m)^flagg0=(.*)$', ('flagg0=' + $flagg0))
$text = [regex]::Replace($text,'(?m)^flagh0=(.*)$', ('flagh0=' + $flagh0))
$text = [regex]::Replace($text,'(?m)^flagi0=(.*)$', ('flagi0=' + $flagi0))
$text = [regex]::Replace($text,'(?m)^flagj0=(.*)$', ('flagj0=' + $flagj0))
$text = [regex]::Replace($text,'(?m)^flagk0=(.*)$', ('flagk0=' + $flagk0))
$text = [regex]::Replace($text,'(?m)^tflag0=(.*)$', ('tflag0=' + $tflag0))
[IO.File]::WriteAllText($test,$text)
Write-Host ("variant profile: {0}" -f $test)
Write-Host ("  flag0=0x{0:X8}  flagi0=0x{1:X8}  flagj0=0x{2:X8}  tflag0=0x{3:X8}" -f $flag0,$flagi0,$flagj0,$tflag0)

# ---------- clean relaunch ----------
Get-Process -Name Hedz  -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Get-Process -Name dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 800

Remove-Item (Join-Path $rt 'dxwnd.log') -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\GAMES\HEDZ\dxwnd.log'   -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $rt 'texture.out') -Recurse -Force -ErrorAction SilentlyContinue

Start-Process -FilePath $exe -ArgumentList '/T','/Q' -WorkingDirectory $rt | Out-Null
Start-Sleep -Seconds 3
Start-Process -FilePath $exe -ArgumentList ('/Y:"' + $test + '"') -WorkingDirectory $rt | Out-Null
Write-Host ''
Write-Host ("[{0}] launched. Navigate: New Game -> heads selection screen." -f $Variant.ToUpper())
Write-Host '  Look at the heads: white (bug) or textured (fixed)? Then quit the game.'
if($Variant -eq 'texdump'){ Write-Host '  (dump run - after quitting, texture.out + dxwnd.log will be analyzed)' }
