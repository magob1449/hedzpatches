#Requires -Version 5.1
<#
.SYNOPSIS
    build-mss32.ps1 - Builds (and optionally installs) the mss32.dll logging proxy
    for H.E.D.Z., the instrument that shows what the game tells Miles Sound System.

.DESCRIPTION
    Why it is needed (all measured, none assumed):

      * D:\Hedz\Music\1.mus IS opened and read in 32 KB chunks through the whole
        level (356 reads / ~85 s in the last capture), so file access, the CD
        path and the streaming loop are all fine.
      * Sound effects play (samples out of SoundFX.dat), and the title music
        plays - F.MUS, IMA ADPCM, opened with AIL_open_stream straight off the
        disc.
      * The level music is silent even though its bytes are being consumed.

    So the fault is in the handoff to the audio layer, and this proxy sits
    exactly there: it is a real mss32.dll that logs every call (with arguments)
    and then forwards it to the original DLL, renamed mss32_real.dll.

    Only the 31 exports Hedz.exe imports are implemented - the game's entire
    audio requirement, so nothing partial can be relied on and nothing extra is
    needed.

    Log written by the proxy: <game folder>\mss32-proxy.log (also mirrored to
    OutputDebugString).

.PARAMETER Deploy
    Install the proxy into the game folder: the original MSS32.DLL is renamed to
    mss32_real.dll and the proxy is copied in as MSS32.DLL. Reversible.

.PARAMETER Remove
    Undo a previous deploy: delete the proxy and rename mss32_real.dll back.

.PARAMETER GameDir
    Game folder (default C:\GAMES\HEDZ).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mss32.ps1 -Deploy
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mss32.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Deploy,
    [switch]$Remove,
    [string]$GameDir = 'C:\GAMES\HEDZ'
)

$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$build = Join-Path $here 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

# the 31 exports Hedz.exe imports from mss32.dll (from its import table)
$NEEDED = @(
    '_AIL_shutdown@0','_AIL_get_DirectSound_info@12','_AIL_init_sample@4',
    '_AIL_set_sample_address@12','_AIL_set_sample_playback_rate@8','_AIL_sample_ms_position@12',
    '_AIL_set_sample_type@12','_AIL_set_sample_adpcm_block_size@8','_AIL_start_sample@4',
    '_AIL_end_sample@4','_AIL_close_stream@4','_AIL_mem_free_lock@4','_AIL_redbook_stop@4',
    '_AIL_set_sample_loop_count@8','_AIL_set_sample_pan@8','_AIL_mem_alloc_lock@4',
    '_AIL_startup@0','_AIL_set_preference@8','_AIL_allocate_sample_handle@4',
    '_AIL_open_stream@12','_AIL_set_stream_loop_count@8','_AIL_start_stream@4',
    '_AIL_sample_status@4','_AIL_resume_sample@4','_AIL_pause_stream@8','_AIL_stop_sample@4',
    '_AIL_set_stream_volume@8','_AIL_set_sample_volume@8','_AIL_set_sample_ms_position@8',
    '_AIL_redbook_close@4','_AIL_WAV_info@8','_AIL_waveOutOpen@16'
)

function Get-PeExports {
    param([byte[]]$b)
    $lfanew  = [BitConverter]::ToInt32($b, 0x3C)
    $machine = [BitConverter]::ToUInt16($b, $lfanew + 4)
    $nsec    = [BitConverter]::ToUInt16($b, $lfanew + 6)
    $optSize = [BitConverter]::ToUInt16($b, $lfanew + 20)
    $opt     = $lfanew + 24
    $magic   = [BitConverter]::ToUInt16($b, $opt)
    $dd      = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $expRva  = [BitConverter]::ToUInt32($b, $dd)

    $result = [pscustomobject]@{ Machine = $machine; Exports = @() }
    if ($expRva -eq 0) { return $result }

    $secTab = $opt + $optSize
    $rva2off = { param($rva)
        for ($i = 0; $i -lt $nsec; $i++) {
            $s  = $secTab + 40 * $i
            $vs = [BitConverter]::ToUInt32($b, $s + 8)
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $pr = [BitConverter]::ToUInt32($b, $s + 20)
            if ($rva -ge $va -and $rva -lt ($va + [Math]::Max($vs, 1))) { return ($rva - $va + $pr) }
        }
        return -1
    }
    $e = & $rva2off $expRva
    if ($e -lt 0) { return $result }

    $base     = [BitConverter]::ToUInt32($b, $e + 16)
    $numNames = [BitConverter]::ToUInt32($b, $e + 24)
    $namesRva = [BitConverter]::ToUInt32($b, $e + 32)
    $names    = & $rva2off $namesRva
    if ($names -lt 0) { return $result }

    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $numNames; $i++) {
        $nRva = [BitConverter]::ToUInt32($b, $names + 4 * $i)
        $nOff = & $rva2off $nRva
        if ($nOff -lt 0) { continue }
        $end = $nOff; while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        $list.Add([Text.Encoding]::ASCII.GetString($b, $nOff, $end - $nOff))
    }
    $result.Exports = $list
    return $result
}

Write-Host '=== mss32.dll logging proxy (32-bit) ===' -ForegroundColor Cyan
Write-Host ("game folder : {0}" -f $GameDir)

if ($Remove) {
    $proxy = Join-Path $GameDir 'MSS32.DLL'
    $real  = Join-Path $GameDir 'mss32_real.dll'
    if (Test-Path $real) {
        if (Test-Path $proxy) { Remove-Item $proxy -Force }
        Rename-Item $real 'MSS32.DLL' -Force
        Write-Host 'Proxy removed - original MSS32.DLL restored.' -ForegroundColor Green
    } else {
        Write-Host 'Nothing to remove (mss32_real.dll not present).'
    }
    return
}

# ---- 1. source the ORIGINAL mss32.dll ----
$realDll = Join-Path $GameDir 'mss32_real.dll'
if (-not (Test-Path $realDll)) { $realDll = Join-Path $GameDir 'MSS32.DLL' }
if (-not (Test-Path $realDll)) { throw "Original mss32.dll not found in $GameDir" }
$realCopy = Join-Path $build 'mss32_real.dll'
Copy-Item $realDll $realCopy -Force
$srcPe = Get-PeExports ([IO.File]::ReadAllBytes($realCopy))
Write-Host ("source      : {0}  ({1} exports, machine 0x{2:X4})" -f (Split-Path $realDll -Leaf), $srcPe.Exports.Count, $srcPe.Machine)
if ($srcPe.Machine -ne 0x014C) { throw 'Source mss32 is not 32-bit.' }
foreach ($n in $NEEDED) {
    if ($srcPe.Exports -notcontains $n) { throw "Source DLL is missing expected export $n - is this the right mss32.dll?" }
}

# ---- 2. compile ----
Copy-Item (Join-Path $here 'mss32_stub.c') $build -Force

$vcvars = $null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath) { $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat' }
}
if (-not $vcvars -or -not (Test-Path $vcvars)) {
    foreach ($root in ${env:ProgramFiles}, ${env:ProgramFiles(x86)}) {
        $vsRoot = Join-Path $root 'Microsoft Visual Studio'
        if (-not (Test-Path $vsRoot)) { continue }
        Get-ChildItem $vsRoot -Directory | ForEach-Object {
            Get-ChildItem $_.FullName -Directory | ForEach-Object {
                $p = Join-Path $_.FullName 'VC\Auxiliary\Build\vcvarsall.bat'
                if (Test-Path $p) { $vcvars = $p }
            }
        }
    }
}
if (-not $vcvars) { throw 'Visual Studio C++ tools not found. Install the Desktop development with C++ workload.' }

$buildCmd = Join-Path $build 'build.cmd'
@"
@echo off
cd /d "%~dp0"
set "PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer;%PATH%"
call "$vcvars" x86
cl /nologo /LD /O2 /W3 /MT mss32_stub.c /Fe:mss32.dll /link /MACHINE:X86
"@ | Set-Content -Path $buildCmd -Encoding ASCII

Write-Host 'compiling (x86 via vcvarsall)...'
$output = cmd /c "`"$buildCmd`" 2>&1"
$built = Join-Path $build 'mss32.dll'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $built)) {
    $output | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    throw 'Build failed - see compiler output above.'
}

# ---- 3. verify ----
$outPe = Get-PeExports ([IO.File]::ReadAllBytes($built))
if ($outPe.Machine -ne 0x014C) { throw 'Built proxy is not 32-bit.' }
$missing = @($NEEDED | Where-Object { $outPe.Exports -notcontains $_ })
if ($missing.Count) { throw ("Built proxy is missing exports: {0}" -f ($missing -join ', ')) }
Write-Host ("built OK    : {0}  (x86, all {1} required exports present)" -f $built, $NEEDED.Count) -ForegroundColor Green

# ---- 4. deploy ----
if ($Deploy) {
    $realTarget = Join-Path $GameDir 'mss32_real.dll'
    $proxyTarget = Join-Path $GameDir 'MSS32.DLL'
    if (-not (Test-Path $realTarget)) {
        Rename-Item $proxyTarget 'mss32_real.dll' -Force
        Write-Host 'original MSS32.DLL -> mss32_real.dll'
    }
    Copy-Item $built $proxyTarget -Force
    Remove-Item (Join-Path $GameDir 'mss32-proxy.log') -Force -ErrorAction SilentlyContinue
    Write-Host ("deployed    : {0} -> {1}" -f $built, $proxyTarget) -ForegroundColor Green
    Write-Host ("log         : {0}" -f (Join-Path $GameDir 'mss32-proxy.log'))
    Write-Host 'revert with : powershell -File .\build-mss32.ps1 -Remove'
}
