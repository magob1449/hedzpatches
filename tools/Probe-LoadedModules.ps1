<#
.SYNOPSIS
    Probe-LoadedModules.ps1 - which DLLs are ACTUALLY loaded in Hedz.exe, and does
    the process exit on its own?

.DESCRIPTION
    Hedz.exe is a 32-bit (WOW64) process. A 64-bit PowerShell can only enumerate
    the 64-bit host modules (ntdll, wow64*.dll) of such a process and reports
    every real module as missing - which is exactly the wrong answer this script
    used to give.

    So it checks its own bitness and, if 64-bit, quietly re-runs itself under
    C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe where the 32-bit
    module list is visible.

    Then it launches Hedz.exe, waits for it to settle, lists the modules that
    matter for this project, and finally watches to see whether the process exits
    by itself (it does: clean exit, code 0, ~9-25 s - it is bailing out, not
    crashing).

    Read-only: writes only .\tools\_mod.out.
#>
$ErrorActionPreference = 'Stop'

# ---- 32-bit view required for a WOW64 target ----
if ([IntPtr]::Size -eq 8) {
    $wow = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $wow)) { throw "32-bit PowerShell not found at $wow" }
    Write-Host '64-bit shell detected - re-launching under 32-bit PowerShell for a real module list...'
    & $wow -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$exe     = 'C:\GAMES\HEDZ\Hedz.exe'
$gameDir = Split-Path $exe -Parent
$out     = Join-Path $PSScriptRoot '_mod.out'

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }

Say ("running as: {0}-bit PowerShell  (required: 32-bit)" -f $(if ([IntPtr]::Size -eq 4) { '32' } else { '64' }))

Say ''
Say '=== Is ddraw.dll a KnownDLL? (a KnownDLL overrides a local copy) ==='
$names = @()
$kdl = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\KnownDLLs'
if (Test-Path $kdl) {
    $names = (Get-ItemProperty $kdl).PSObject.Properties |
             Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Value }
}
if ($names | Where-Object { $_ -like '*ddraw*' }) { Say '  ddraw IS a KnownDLL' }
else { Say '  ddraw.dll is NOT a KnownDLL - a copy beside the exe will be loaded' }
Say ("  (winmm KnownDLL: {0})" -f $(if ($names | Where-Object { $_ -like '*winmm*' }) { 'yes' } else { 'no' }))

Say ''
Say '=== Launch and list modules ==='
$p = Start-Process -FilePath $exe -WorkingDirectory $gameDir -PassThru
Say ("  launched pid {0}" -f $p.Id)
Start-Sleep -Seconds 9

if ($p.HasExited) {
    Say ("  EXITED on its own within 9s - code {0}" -f $p.ExitCode)
} else {
    $mods = (Get-Process -Id $p.Id).Modules
    Say ("  module count: {0}" -f $mods.Count)
    foreach ($w in 'ddraw.dll','winmm.dll','mss32.dll','TruePlay.dll','DSOUND.dll','gdi32.dll','user32.dll','kernel32.dll') {
        $m = $mods | Where-Object { $_.ModuleName -ieq $w } | Select-Object -First 1
        if ($m) { Say ("  {0,-14} {1}" -f $m.ModuleName, $m.FileName) }
        else    { Say ("  {0,-14} NOT LOADED" -f $w) }
    }
    $d = $mods | Where-Object { $_.ModuleName -ieq 'ddraw.dll' } | Select-Object -First 1
    if ($d) {
        Say ''
        if ($d.FileName -ieq (Join-Path $gameDir 'ddraw.dll')) {
            Say '  ==> the local wrapper (pal-ddraw) IS the active DirectDraw provider'
        } else {
            Say ("  ==> the SYSTEM ddraw is active instead: {0}" -f $d.FileName)
        }
    }
}

Say ''
Say '=== Does it exit by itself if left completely alone? ==='
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    if ($p.HasExited) { Say ("  process ended on its own after ~{0}s, code {1}" -f (9 + $i + 1), $p.ExitCode); break }
}
if (-not $p.HasExited) { Say '  still running after ~54s with zero input'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

[IO.File]::WriteAllLines($out, $lines)
Write-Host ''; Write-Host ("report: {0}" -f $out)
