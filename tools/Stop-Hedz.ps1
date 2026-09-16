<#
.SYNOPSIS
    Stop-Hedz.ps1 - stops Hedz.exe and DxWnd, reporting what was running.

.DESCRIPTION
    Diagnostics here start DxWnd and the game, and some runs are elevated (the
    Process Monitor traces). An elevated DxWnd server therefore survives a
    non-elevated cleanup attempt - killing an elevated process from a normal
    shell fails with "Access is denied" - and a second DxWnd instance can then
    hook the game at a higher integrity level than the caller.

    Run this elevated if the non-elevated pass reports access denied.
#>
param([switch]$WhatIf)
$ErrorActionPreference='Continue'

$any=$false
foreach($n in 'Hedz','dxwnd','Procmon64','Procmon'){
    $ps=Get-Process -Name $n -ErrorAction SilentlyContinue
    if($ps){
        $any=$true
        foreach($p in $ps){
            $denied=$false
            if(-not $WhatIf){
                try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { $denied=$true }
            }
            Write-Host ("  {0,-10} pid {1,-8} {2}" -f $p.ProcessName,$p.Id,$(if($WhatIf){'would stop'}elseif($denied){'ACCESS DENIED - re-run this script elevated'}else{'stopped'}))
        }
    }
}
if(-not $any){ Write-Host '  nothing to stop - no Hedz / DxWnd / ProcMon processes running' }
