#Requires -Version 5.1
<#
.SYNOPSIS
    Verify-SetupExe.ps1 - Forensic inspection of the H.E.D.Z. CD installer binaries.

.DESCRIPTION
    Proves (from raw bytes, not guesswork) whether the CD's SETUP.EXE / _SETUP.DLL /
    AUTORUN.EXE are 16-bit NE-format programs, which is the root cause of
    "This app can't run on your PC" on 64-bit Windows 10/11 (no NTVDM, no WOW16 on x64).

    Also fingerprints the InstallShield version from _INST32I.EX_ so you know which
    extraction approach applies, and reports whether the CD layout matches the
    known-good H.E.D.Z. layout this project was built against.

.NOTES
    Read-only. Makes no changes to the CD, the registry, or the filesystem.
    Run from anywhere:  powershell -NoProfile -ExecutionPolicy Bypass -File .\Verify-SetupExe.ps1 -CdPath D:\
#>
[CmdletBinding()]
param(
    # Drive letter or full path of the mounted HEDZ CD (must contain SETUP.EXE).
    [string]$CdPath = 'D:'
)

$ErrorActionPreference = 'Stop'

function Read-Header {
    param([string]$File, [int]$Bytes = 256)
    try   { return [IO.File]::ReadAllBytes($File) }
    catch { Write-Warning ("Cannot read {0}: {1}" -f $File, $_.Exception.Message); return $null }
}

function Format-HexDump {
    param([byte[]]$Data, [int]$Length = 64)
    $take = [Math]::Min($Length, $Data.Length)
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $take; $i += 16) {
        $row = for ($j = $i; $j -lt [Math]::Min($i + 16, $take); $j++) { $Data[$j].ToString('X2') }
        [void]$sb.Append(('{0:X4}  {1}' -f $i, ($row -join ' ')))
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}

# Returns a diagnosis string for one executable image.
function Get-ImageDiagnosis {
    param([byte[]]$Data)

    if (-not $Data -or $Data.Length -lt 64) { return 'unreadable / too small' }

    $mz = [Text.Encoding]::ASCII.GetString($Data, 0, 2)
    if ($mz -ne 'MZ') { return 'not an MZ/NE/PE executable image' }

    # e_lfanew (offset of new EXE header) = little-endian uint32 at 0x3C
    $lfanew = [BitConverter]::ToUInt32($Data, 0x3C)

    $neOk = ($lfanew + 2) -lt $Data.Length -and
            [Text.Encoding]::ASCII.GetString($Data, [int]$lfanew, 2) -eq 'NE'
    $peOk = ($lfanew + 4) -lt $Data.Length -and
            [Text.Encoding]::ASCII.GetString($Data, [int]$lfanew, 2) -eq 'PE'

    if ($neOk) {
        return '16-BIT NE EXECUTABLE  ->  cannot run on x64 Windows (no NTVDM / WOW16)'
    }
    if ($peOk) {
        $machine = [BitConverter]::ToUInt16($Data, [int]$lfanew + 4)
        switch ($machine) {
            0x014C { return '32-bit PE (i386) - should run on x64 Windows via WoW64' }
            0x8664 { return '64-bit PE (x64)' }
            default { return ('PE, unknown machine 0x{0:X4}' -f $machine) }
        }
    }
    # Self-extracting / generic MS-DOS overlay: MZ but no NE/PE at e_lfanew.
    return 'MS-DOS MZ image (no NE/PE header) - 16-bit DOS stub, blocked on x64 Windows'
}

# InstallShield engines stamp _INST32I.EX_ with a copyright banner.
function Get-InstallShieldFingerprint {
    param([string]$Path)
    $bytes = Read-Header $Path 512
    if (-not $bytes) { return 'not found' }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if ($text -match 'Copyright \(c\) (\d{4})-(\d{4})') {
        return ('InstallShield engine (c) {0}-{1}' -f $Matches[1], $Matches[2])
    }
    if ($bytes[0] -eq 0x2A -and $bytes[1] -eq 0xAB) {
        return 'InstallShield 5.x compressed engine (0x2AAB LZS signature)'
    }
    return 'unknown engine format'
}

Write-Host '=== H.E.D.Z. CD installer forensics ===' -ForegroundColor Cyan
Write-Host ("CD path : {0}" -f $CdPath)
Write-Host ''

$targets = @('SETUP.EXE', '_SETUP.DLL', 'AUTORUN.EXE', '_ISDEL.EXE')
foreach ($name in $targets) {
    $full = Join-Path $CdPath $name
    if (-not (Test-Path $full)) { Write-Host ('{0,-12}: not present on this CD' -f $name); continue }
    $data = Read-Header $full
    $size = (Get-Item $full).Length
    Write-Host ('{0} ({1:N0} bytes)' -f $name, $size) -ForegroundColor Yellow
    Write-Host (Format-HexDump $data 48)
    Write-Host ('DIAGNOSIS : ' + (Get-ImageDiagnosis $data))
    Write-Host ''
}

$isdbgn = Join-Path $CdPath 'ISDBGN.DLL'
if (Test-Path $isdbgn) {
    $data = Read-Header $isdbgn 64
    Write-Host ('ISDBGN.DLL          : {0}' -f (Get-ImageDiagnosis $data))
}
$engine = Join-Path $CdPath '_INST32I.EX_'
if (Test-Path $engine) {
    Write-Host ('_INST32I.EX_ engine : {0}' -f (Get-InstallShieldFingerprint $engine))
}

# Layout sanity check - the file list this toolkit was built against.
Write-Host ''
Write-Host '=== CD layout check (known-good HEDZ layout) ===' -ForegroundColor Cyan
$expect = 'SETUP.EXE','_SETUP.DLL','SETUP.INS','_INST32I.EX_','Hedz\Hedz.exe','Hedz\TruePlay.dll','Hedz\MSS32.DLL','Hedz\MSS16.DLL','Hedz\hedz.hdz','Hedz\Music\1.mus','Hedz\Music\1.AMB','Hedz\Movies\HDZintro.avi','redist\directx','Support\Glide'
foreach ($rel in $expect) {
    $full = Join-Path $CdPath $rel
    if (Test-Path $full) {
        Write-Host ('  [OK]   {0}' -f $rel) -ForegroundColor Green
    } else {
        Write-Host ('  [MISS] {0}' -f $rel) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'Key: 16-bit NE executables are the reason setup.exe fails with'
Write-Host '"This app can''t run on your PC" on Windows 10/11 x64.'
Write-Host 'Remedy: run the installer under otvdm (16-bit host), or do a manual'
Write-Host 'install with Install-Hedz.ps1 + hedz-install.reg (see README.md).'
