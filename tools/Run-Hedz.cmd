@echo off
rem ====================================================================
rem  H.E.D.Z. launcher - runs the game through DxWnd with the OFFICIAL
rem  H.E.D.Z. profile, which forces the render window to 800x600.
rem
rem  Without this the game opens a black window the size of the whole
rem  desktop (1920x1080) on top of its own menu, which makes the menu
rem  unclickable and looks like a crash.
rem
rem  It also retires pal-ddraw for the session so DxWnd is the single
rem  authoritative DirectDraw layer.
rem
rem  Any arguments are passed through, e.g.:
rem      Run-Hedz.cmd -Wait            wait for the game, then stop DxWnd
rem      Run-Hedz.cmd -KeepPalDdraw    leave pal-ddraw in place
rem ====================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Hedz.ps1" %*
if errorlevel 1 pause
