#Requires -Version 5.1
<#
.SYNOPSIS
    _test_stub.ps1 - Compile and run the 32-bit functional test of the winmm
    CD-presence proxy.

.DESCRIPTION
    test_stub.c loads "winmm.dll" from ITS OWN folder (the loader searches the
    application directory first) so it exercises the built proxy rather than
    the system DLL, then checks the synthetic cdaudio device and confirms that
    a non-intercepted call is still answered by the real winmm via the linker
    forwarders.

    Run build-winmm.ps1 first - this script needs tools\cdstub\build\winmm.dll
    and winmm_real.dll to exist.

    Expected (verified on the reference machine):
        open cdaudio alias testcd        rc=0
        status testcd media present      -> 'true'
        status testcd mode               -> 'stopped'
        status testcd ready              -> 'true'
        play testcd                      rc=0
        status testcd mode               -> 'playing'
        ...
        sysinfo all quantity             -> answered by REAL winmm
        DONE

.NOTES
    The proxy is NOT needed for H.E.D.Z. itself (Hedz.exe contains no
    cdaudio/MCI code). This test exists so the tool is proven before being
    used on a title that genuinely depends on MCI media presence.
#>
[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$build = Join-Path $here 'build'

Write-Host '=== winmm proxy functional test (32-bit) ===' -ForegroundColor Cyan

foreach ($req in 'winmm.dll', 'winmm_real.dll') {
    $p = Join-Path $build $req
    if (-not (Test-Path $p)) {
        throw "Missing $p - run .\build-winmm.ps1 first."
    }
}
Write-Host ("proxy      : {0}" -f (Join-Path $build 'winmm.dll'))

Copy-Item (Join-Path $here 'test_stub.c') $build -Force

# ---- locate Visual Studio (same search as build-winmm.ps1) ----
$vcvars  = $null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath) { $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat' }
}
if (-not $vcvars -or -not (Test-Path $vcvars)) {
    foreach ($root in "${env:ProgramFiles}", "${env:ProgramFiles(x86)}") {
        $vsRoot = Join-Path $root 'Microsoft Visual Studio'
        if (-not (Test-Path $vsRoot)) { continue }
        Get-ChildItem $vsRoot | Where-Object { $_.PSIsContainer } | ForEach-Object {
            Get-ChildItem $_.FullName | Where-Object { $_.PSIsContainer } | ForEach-Object {
                $p = Join-Path $_.FullName 'VC\Auxiliary\Build\vcvarsall.bat'
                if (Test-Path $p) { $vcvars = $p }
            }
        }
    }
}

if (-not $vcvars -or -not (Test-Path $vcvars)) {
    Write-Warning 'Visual Studio C++ tools not found. Build the test manually:'
    Write-Host '  1. Open the "x86 Native Tools Command Prompt for VS 2022"'
    Write-Host ("  2. cd /d `"$build`"")
    Write-Host '  3. cl /nologo /O2 /W3 /MT test_stub.c /Fe:test_stub.exe /link /MACHINE:X86 /NODEFAULTLIB:winmm.lib'
    Write-Host '  4. test_stub.exe'
    return
}

$testCmd = Join-Path $build 'test.cmd'
@"
@echo off
cd /d "%~dp0"
rem vcvarsall calls vswhere.exe by bare name in some builds
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
call "$vcvars" x86
rem vcvarsall leaves the CWD somewhere else - come back so cl finds the source
cd /d "%~dp0"
cl /nologo /O2 /W3 /MT test_stub.c /Fe:test_stub.exe /link /MACHINE:X86 /NODEFAULTLIB:winmm.lib
if errorlevel 1 exit /b 1
rem run with an explicit path AND this folder as CWD so the loader resolves
rem "winmm.dll" to the local proxy instead of the one in SysWOW64
"%~dp0test_stub.exe"
"@ | Set-Content -Path $testCmd -Encoding ASCII

Write-Host 'compiling + running...' -ForegroundColor DarkGray
# note: test_stub must run with build\ as the CWD so the loader picks up the
# local proxy - test.cmd does its own cd /d "%~dp0".
$output = cmd /c "`"$testCmd`" 2>&1"
$code = $LASTEXITCODE
$output | ForEach-Object { Write-Host ('  ' + $_) }

# ---- assert the important results ----
$text = ($output -join "`n")
$fail = @()
if ($text -notmatch "open cdaudio alias testcd\s+rc=0")            { $fail += 'open cdaudio did not return rc=0' }
if ($text -notmatch "media present\s+rc=0\s+->'true'|media present\s+rc=0.*'true'") { $fail += "media present did not report 'true'" }
if ($text -notmatch "play testcd\s+rc=0")                          { $fail += 'play did not return rc=0' }
if ($text -notmatch "mode\s+rc=0\s+->'playing'|mode\s+rc=0.*'playing'")             { $fail += "mode did not become 'playing'" }
if ($text -notmatch "sysinfo all quantity\s+rc=0\s+->'[^']")         { $fail += 'forwarded sysinfo call returned nothing (real winmm forwarding broken?)' }

Write-Host ''
if ($fail.Count -eq 0 -and $code -eq 0) {
    Write-Host 'PASS - synthetic cdaudio works and non-intercepted calls reach the real winmm.' -ForegroundColor Green
} else {
    Write-Host 'FAIL:' -ForegroundColor Red
    $fail | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
    Write-Host ("  (exit code $code)") -ForegroundColor Red
}

if (-not $KeepArtifacts) {
    foreach ($a in 'test_stub.exe', 'test_stub.obj') {
        $p = Join-Path $build $a
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}
exit ($(if ($fail.Count -eq 0) { 0 } else { 1 }))
