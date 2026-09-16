@echo off
rem ====================================================================
rem  H.E.D.Z. launcher - FINAL architecture: the game runs with
rem  DDrawCompat (ddraw.dll in the game folder) and nothing else.
rem
rem  DDrawCompat renders DirectDraw/Direct3D 1-7 through D3D11 on the
rem  GPU - this is what fixes the white in-level loadout icons AND
rem  gives hardware-quality rendering. The mss32 proxy next to it
rem  streams the .mus music from the CD.
rem
rem  Any arguments are passed through, e.g.:
rem      Run-Hedz.cmd -Wait     block until the game exits
rem ====================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Hedz.ps1" %*
if errorlevel 1 pause
