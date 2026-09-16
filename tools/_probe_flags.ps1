$ErrorActionPreference = 'Stop'
$rt   = Join-Path $PSScriptRoot 'dxwnd\runtime'
$prof = Join-Path $PSScriptRoot 'dxwnd\HEDZ.dxw'
$probe= Join-Path $PSScriptRoot 'dxwnd\PROBE.dxw'

# --- build probe: every flag group fully set, target cmd.exe (harmless hook target) ---
$text = Get-Content $prof -Raw
$text = [regex]::Replace($text,'(?m)^title0=.*$',        'title0=PROBE')
$text = [regex]::Replace($text,'(?m)^path0=.*$',         'path0=C:\GAMES\HEDZ\Hedz.exe')
foreach($k in 'flag0','flagg0','flagh0','flagi0','flagj0','flagk0','flagl0','flagm0','flagn0','flago0'){
    $text = [regex]::Replace($text,('(?m)^{0}=.*$' -f $k), ('{0}=4294967295' -f $k))
}
# keep only OUTTRACE (bit 0x1, verified working on this binary) so the banner prints
$text = [regex]::Replace($text,'(?m)^tflag0=.*$', 'tflag0=1')
[IO.File]::WriteAllText($probe,$text)
Write-Host "probe written: $probe"

# --- clean previous logs so we only read this run ---
Remove-Item (Join-Path $rt 'dxwnd.log') -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\GAMES\HEDZ\dxwnd.log'   -Force -ErrorAction SilentlyContinue

# --- run probe ---
Get-Process -Name Hedz,notepad,dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 700
Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList '/T','/Q' -WorkingDirectory $rt | Out-Null
Start-Sleep -Seconds 3
$p = Start-Process -FilePath (Join-Path $rt 'dxwnd.exe') -ArgumentList ('/Y:"' + $probe + '"') -WorkingDirectory $rt -PassThru
$p.WaitForExit(12000) | Out-Null
Start-Sleep -Seconds 4
# the banner prints at hook-init; give the game a moment then harvest regardless of its fate
Start-Sleep -Seconds 2

Get-Process -Name notepad,dxwnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }

# --- harvest the banner ---
Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
foreach($log in (Join-Path $rt 'dxwnd.log'), 'C:\GAMES\HEDZ\dxwnd.log'){
    if(Test-Path $log){
        Write-Host ("`n=== {0} ===" -f $log)
        Get-Content $log | Select-Object -First 250
    }
}
