<#
.SYNOPSIS
    _probe_group.ps1 - locate which flags group (and bit) is SURFACEUNLOCK.

.DESCRIPTION
    Writes HEDZ-probe.dxw = canonical profile with ONE flags key set to
    <base> | <mask> and tflag0=0x803 (the proven log recipe: OUTTRACE +
    LOGERRORS + OUTALLERRORS), runs the game ~18 s, then greps the
    dxwnd.log hook-init banner for SURFACEUNLOCK.

    Phase 1 (group scan): -Key flagk0|flagl0|flagm0|flagn0|flago0 -Mask 0xFFFFFFFF
    Phase 2 (bit bisect): same key, -Mask 0xFFFF0000 then narrower

    Usage:
        powershell -File tools\_probe_group.ps1 -Key flagk0 -Mask 0xFFFFFFFF
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Key,          # .dxw flags key: flagk0, flagl0, flagm0, flagn0, flago0 ...
    [Parameter(Mandatory=$true)]
    [string]$Mask          # hex like 0xFFFF0000 or decimal
)
$ErrorActionPreference = 'Stop'

$rt    = Join-Path $PSScriptRoot 'dxwnd\runtime'
$prof  = Join-Path $PSScriptRoot 'dxwnd\HEDZ.dxw'
$probe = Join-Path $PSScriptRoot 'dxwnd\HEDZ-probe.dxw'
$mask  = [uint32]$Mask

# base value of the target key, taken from the canonical profile
$base = [uint32]0
$text = Get-Content $prof -Raw
$m = [regex]::Match($text, ('(?m)^{0}=(\d+)$' -f $Key))
if($m.Success){ $base = [uint32]$m.Groups[1].Value }

$combined = [uint32]((([int64]$base) -bor ([int64]$mask)) -band 4294967295)

# probe = canonical profile with the one key ORed and the proven trace bits
$text = [regex]::Replace($text,'(?m)^title0=.*$',  'title0=HEDZPROBE')
$text = [regex]::Replace($text,('(?m)^{0}=.*$' -f $Key), ('{0}={1}' -f $Key,$combined))
$text = [regex]::Replace($text,'(?m)^tflag0=.*$',  'tflag0=2051')
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
    Write-Host ("RESULT key={0} mask=0x{1:X8} combined=0x{2:X8} (base 0x{3:X8})  SURFACEUNLOCK: {4}" -f $Key,$mask,$combined,$base,$hit)
    if($hit){
        Write-Host '--- banner line with the hit ---'
        Select-String -Path $log -Pattern 'SURFACEUNLOCK' | ForEach-Object { $_.Line }
    } else {
        Write-Host '--- banner (first 20 lines) ---'
        Get-Content $log | Select-Object -First 20
    }
} else {
    Write-Host ("RESULT key={0} mask=0x{1:X8} combined=0x{2:X8}  NO LOG PRODUCED" -f $Key,$mask,$combined)
}
