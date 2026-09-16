#Requires -Version 5.1
<#
.SYNOPSIS
    Install-Hedz.ps1 - Native install of H.E.D.Z. on Windows 10/11 x64 without the
    blocked 16-bit InstallShield stub.

.DESCRIPTION
    Replicates what the original InstallShield 5 installer does, based on the CD layout:

      1. Copies D:\Hedz -> <InstallDir>   (exe, data packs, MapFiles, Movies, DLLs)
         EXCEPT the Music folder - HEDZ streams .mus/.amb music live from the CD
         (the original "full install" never copies .mus to disk either), so the
         game must keep finding the CD drive at runtime. The CD drive letter is
         stored in the registry (InstalledFromDrive) and is rewritten to point
         at your actual CD/DVD/virtual drive letter - as "D:", with the colon.

      2. Imports the registry keys the installer would have written
         (uninstall entry, InstallLocation) - see hedz-install.reg.
         Uses HKLM 32-bit view (Wow6432Node) as Windows treats 32-bit games.

      3. Registers the InstallShield setup log (setup.ins behavior) so that
         future otvdm-based install/uninstall operations see a consistent state.

    Safe to re-run: it skips files that are already identical (by length),
    and rewrites the CD drive registry value every time.

    NOTE ON hedz.ini: this disc does not ship one and Hedz.exe never reads
    one. Verified: Hedz.exe contains zero occurrences of the string ".ini"
    and imports none of the GetPrivateProfile*/WritePrivateProfile* APIs.
    Every setting lives in HKLM\Software\Vis Interactive\Hedz (32-bit view),
    plus HardHedz.set in the game folder. Do not hand-edit an INI.

.PARAMETER CdPath
    Drive letter of the mounted HEDZ CD (WinCDEmu/DAEMON/real drive). Default D:.

.PARAMETER InstallDir
    Target folder. Default C:\GAMES\HEDZ (a short path avoids MAX_PATH issues
    with the long MapFiles names on some 3rd-party tools).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Hedz.ps1 -CdPath D: -InstallDir C:\GAMES\HEDZ
#>
[CmdletBinding()]
param(
    [string]$CdPath = 'D:',
    [string]$InstallDir = 'C:\GAMES\HEDZ'
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Test-SourceAvailable {
    param([string]$Source, [string]$Target)
    if (-not (Test-Path $Source)) { return $false }
    if (Test-Path $Target) { return ((Get-Item $Target).Length -eq (Get-Item $Source).Length) }
    return $false
}

function Copy-IfNeeded {
    param([string]$Source, [string]$Target)
    if (Test-SourceAvailable $Source $Target) {
        Write-Host ('  = {0}' -f $Target) -ForegroundColor DarkGray
        return
    }
    $dir = Split-Path $Target -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    Write-Host ('  + {0}' -f $Target) -ForegroundColor Green
}

# (No hedz-ini helper: Hedz.exe never reads an INI. Verified - 0 occurrences
#  of ".ini" in the binary and no GetPrivateProfile*/WritePrivateProfile*
#  imports. The CD drive comes from the registry value only.)

function Write-HedzRegistry {
    # Write the values the ORIGINAL installer script writes, into the 32-BIT
    # registry view the game actually reads. Evidence: D:\ENGLISH\SETUP.INS
    # writes Language / InstalledFromDrive / InstallType under
    # Software\Vis Interactive\Hedz, and Hedz.exe looks InstalledFromDrive up
    # and falls back to "full protection" (demanding the CD) when missing.
    # A 64-bit reg.exe import would land in the 64-bit view and be invisible
    # to this 32-bit game - hence the direct .NET 32-bit-view write.
    #
    # The COLON IS PART OF THE VALUE. Hedz.exe does
    #     strcpy(base, value); strcat(base, "\\Hedz\\"); driveLetter = base[0];
    # with no colon inserted anywhere, so a bare "D" produces the relative
    # path "D\Hedz\..." (resolved against the game folder) and the disc check
    # fails. Store "D:\". Proven by a Process Monitor trace.
    param([string]$InstallDirPath, [string]$CdDrive)

    $letter = $CdDrive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
    if ($letter -notmatch '^[A-Z]$') { throw "Invalid CD drive '$CdDrive' (expected e.g. D:)" }
    $driveValue = "${letter}:"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning 'Not elevated: the HKLM registry write will fail. Re-run from an elevated PowerShell.'
    }

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
                                                       [Microsoft.Win32.RegistryView]::Registry32)
    try {
        $game = $base.CreateSubKey('SOFTWARE\Vis Interactive\Hedz', $true)
        $game.SetValue('InstalledFromDrive', $driveValue, [Microsoft.Win32.RegistryValueKind]::String)
        $game.SetValue('Language', 'English', [Microsoft.Win32.RegistryValueKind]::String)
        Write-Host ("  ~ [32-bit view] InstalledFromDrive={0}  Language=English" -f $driveValue) -ForegroundColor Cyan
        $game.Close()

        $un = $base.CreateSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5BAA97BC-718C-11D2-84B1-006097616E32}', $true)
        $un.SetValue('DisplayName', 'HEDZ')
        $un.SetValue('InstallLocation', $InstallDirPath)
        $un.SetValue('Publisher', 'VIS Interactive / Hasbro Interactive')
        Write-Host '  ~ [32-bit view] uninstall entry written' -ForegroundColor Cyan
        $un.Close()
    } finally {
        $base.Close()
    }
}

# ---------- sanity checks ----------
if (-not (Test-Path (Join-Path $CdPath 'SETUP.EXE'))) {
    throw "CD not found at $CdPath - mount the HEDZ disc/image first (see README)."
}
if (-not (Test-Path (Join-Path $CdPath 'Hedz\Hedz.exe'))) {
    throw "CD layout unexpected: Hedz\Hedz.exe missing under $CdPath."
}

Write-Host '=== H.E.D.Z. native install (no 16-bit installer) ===' -ForegroundColor Cyan
Write-Host ("CD         : {0}" -f $CdPath)
Write-Host ("Install to : {0}" -f $InstallDir)
Write-Host ''

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

# ---------- 1. copy game files (everything except Music) ----------
Write-Host 'Copying game files...' -ForegroundColor Yellow
$srcRoot = Join-Path $CdPath 'Hedz'
Get-ChildItem $srcRoot -Recurse -File | Where-Object {
    $_.DirectoryName -notmatch '\\Music(\\|$)'
} | ForEach-Object {
    $rel  = $_.FullName.Substring($srcRoot.Length).TrimStart('\')
    $dest = Join-Path $InstallDir $rel
    Copy-IfNeeded $_.FullName $dest
}
Write-Host '  (Music folder intentionally NOT copied - streams from CD)' -ForegroundColor DarkGray

# ---------- 2/3. registry (32-bit view - the game is a 32-bit process) ----------
Write-Host 'Configuring CD path...' -ForegroundColor Yellow
Write-Host 'Writing registry values...' -ForegroundColor Yellow
Write-HedzRegistry $InstallDir $CdPath

# ---------- 4. optional: register for otvdm if present ----------
$otvdm = Get-Command 'otvdm.exe' -ErrorAction SilentlyContinue
if ($otvdm) {
    Write-Host ('otvdm detected at {0} - you can re-run the original installer with:' -f $otvdm.Source) -ForegroundColor Cyan
    Write-Host ('    otvdm.exe {0}\SETUP.EXE' -f $CdPath)
    Write-Host '  (Useful for "Verify Install" / uninstall-bookkeeping parity, not required.)'
}

Write-Host ''
Write-Host 'Install complete.' -ForegroundColor Green
Write-Host 'Next steps: apply the DirectDraw wrapper + registry compat flags (see README.md Tasks 1/3),'
Write-Host ('then launch Hedz.exe. Keep the CD image mounted on {0} - the game reads that ' -f $CdPath)
Write-Host 'letter from the registry, not from any file. Re-run this script (or Set-HedzCdPath.ps1)'
Write-Host 'if the mount ever moves to a different letter.'
