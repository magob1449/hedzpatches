<#
.SYNOPSIS
    _probe_unlock.ps1 - one binary-search probe for SURFACEUNLOCK's bit.

.DESCRIPTION
    Writes HEDZ-probe.dxw = canonical profile with flagh0 |= <mask>, runs the
    game for ~20 s, then greps dxwnd.log's hook-init banner for SURFACEUNLOCK.
    The banner prints active flag names in bit order at init - if the bit is
    in the mask, the name appears.

    Usage:
        powershell -File tools\_probe_unlock.ps1 -Mask 0xFFFF0000
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Mask          # hex like 0xFFFF0000 or decimal
)
$ErrorActionPreference = 'Stop'

$rt    = Join-Path $PSScriptRoot 'dxwnd\runtime'
$prof  = Join-Path $PSScriptRoot 'dxwnd\HEDZ.dxw'
$probe = Join-Path $PSScriptRoot 'dxwnd\HEDZ-probe.dxw'
$mask  = [uint32]$Mask

# canonical base flagh0 (official profile + FORCESHEL + BILINEARFILTER fixes)
$baseFlagh0 = [uint32]33554454

$combined = [uint32]((([int64]$baseFlagh0) -bor ([int64]$mask)) -band 4294967295)

$text = Get-Content $prof -Raw
$text = [regex]::Replace($text,'(?m)^title0=.*$',  'title0=HEDZPROBE')
$text = [regex]::Replace($text,'(?m)^flagh0=.*$',  ('flagh0={0}' -f $combined))
[IO.File]::WriteAllText($probe,$text)

Remove-Item 'C:\GAMES\HEDZ\dxwnd.log' -Force -ErrorAction SilentlyContinue

Get-Process -Name Hedz,dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 700

Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/T','/Q' -WorkingDirectory $rt | Out-Null
Start-Sleep -Seconds 3
$p = Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList ('/Y:"' + $probe + '"') -WorkingDirectory $rt -PassThru
$p.WaitForExit(15000) | Out-Null
Start-Sleep -Seconds 15

Get-Process -Name Hedz,dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

$log = 'C:\GAMES\HEDZ\dxwnd.log'
if(Test-Path $log){
    $hit = Select-String -Path $log -Pattern 'SURFACEUNLOCK' -Quiet
    Write-Host ("mask=0x{0:X8}  flagh0=0x{1:X8}  SURFACEUNLOCK-in-banner: {2}" -f $mask,$combined,$hit)
    if(-not $hit){ Write-Host '--- banner (first 25 lines) ---'; Get-Content $log | Select-Object -First 25 }
} else {
    Write-Host ("mask=0x{0:X8}  flagh0=0x{1:X8}  NO LOG PRODUCED" -f $mask,$combined)
}
