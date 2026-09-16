#Requires -Version 5.1
<#
.SYNOPSIS
    Run-HedzDebug.ps1 - launch H.E.D.Z. with permission to write its own debug log,
    then dump that log. The game only writes c:\hedzdbg.txt (a hardcoded absolute
    path) if the process may create files in C:\ root, which needs elevation.
    The log names the exact anti-piracy check that fails.

.NOTES
    The game window will appear for ~15 seconds and is then closed automatically.
#>
[CmdletBinding()]
param(
    [string]$GameExe  = 'C:\GAMES\HEDZ\Hedz.exe',
    [int]$WaitSeconds = 15
)

$ErrorActionPreference = 'Continue'
$log = 'C:\hedzdbg.txt'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("elevated   : {0}" -f $isAdmin) -ForegroundColor ($(if ($isAdmin) { 'Green' } else { 'Red' }))

if (-not $isAdmin) {
    Write-Warning 'Not elevated - the game cannot create C:\hedzdbg.txt, so the log will stay empty.'
}

if (-not (Test-Path $GameExe)) { throw "Game not found: $GameExe" }

# clear stale log / artifacts so anything present is definitely from this run
foreach ($p in $log, 'C:\GAMES\HEDZ\test', 'C:\test', 'D:\test') {
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

Write-Host ('launching {0} ...' -f $GameExe)
$proc = Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe -Parent) -PassThru

# poll: watch for the log file appearing, and for the "insert CD" dialog
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$seenLog = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $log) { $seenLog = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $seenLog) {
    Write-Host 'c:\hedzdbg.txt did not appear within the wait window - dumping anyway at the end.'
}

Write-Host 'closing the game...'
Get-Process -Name Hedz -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Milliseconds 800

Write-Host ''
Write-Host '================ C:\hedzdbg.txt ================' -ForegroundColor Cyan
if (Test-Path $log) {
    $fi = Get-Item $log
    Write-Host ("  {0:N0} bytes  written {1}" -f $fi.Length, $fi.LastWriteTime)
    Write-Host '  ---------------------------------------------------'
    Get-Content $log | ForEach-Object { Write-Host ('  ' + $_) }
} else {
    Write-Host '  (file not created)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '================ stray write-test artifacts ================' -ForegroundColor Cyan
foreach ($p in 'C:\GAMES\HEDZ\test', 'C:\test', 'D:\test') {
    if (Test-Path $p) {
        $i = Get-Item $p
        Write-Host ("  FOUND {0}  size={1}  created={2}" -f $p, $i.Length, $i.CreationTime) -ForegroundColor Green
    }
}
Write-Host '  (nothing = no write-test file was left behind)'

Write-Host ''
Write-Host '================ registry after run ================' -ForegroundColor Cyan
$k = 'HKLM:\SOFTWARE\WOW6432Node\Vis Interactive\Hedz'
if (Test-Path $k) {
    (Get-ItemProperty $k).PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } |
        ForEach-Object { Write-Host ("  {0} = {1}" -f $_.Name, $_.Value) }
}
