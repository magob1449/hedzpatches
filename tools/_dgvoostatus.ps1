$ErrorActionPreference='Stop'
# listener first
$listener = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\Capture-DebugMessages.ps1" -PassThru
Start-Sleep -Seconds 2
$p = Start-Process -FilePath 'C:\GAMES\HEDZ\Hedz.exe' -WorkingDirectory 'C:\GAMES\HEDZ' -PassThru
Write-Host ("launched pid {0}" -f $p.Id)
$deadline=(Get-Date).AddSeconds(40)
while(-not $p.HasExited -and (Get-Date) -lt $deadline){ Start-Sleep -Milliseconds 500 }
if($p.HasExited){ Write-Host ("EXITED code=0x{0:X8} ({0})" -f $p.ExitCode) }
else { Write-Host 'still alive after 40s'; Stop-Process -Id $p.Id -Force }
if(-not $listener.HasExited){ Stop-Process -Id $listener.Id -Force -ErrorAction SilentlyContinue }
Get-Content "$PSScriptRoot\trace\debug-messages.txt" -ErrorAction SilentlyContinue | Select-Object -Last 40
