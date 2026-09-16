#Requires -Version 5.1
<#
.SYNOPSIS
    Set-HedzCdPath.ps1 - Register the HEDZ CD drive the way the original
    installer does, in the registry view the game actually reads.

.DESCRIPTION
    Why this is needed
    ------------------
    Hedz.exe (32-bit) reads HKLM\Software\Vis Interactive\Hedz and looks for
    InstalledFromDrive. The original InstallShield script writes:

        Software\Vis Interactive\Hedz
            Language          = e.g. "English"
            InstalledFromDrive= e.g. "D:"       <-- drive letter WITH the colon
            InstallType       = (install type flag)

    Evidence: D:\ENGLISH\SETUP.INS contains exactly those value names.

    THE COLON IS MANDATORY. Hedz.exe concatenates the value verbatim:

        RegQueryValueExA(..., "InstalledFromDrive", ...)
        strcpy(base, value); strcat(base, "\\Hedz\\");
        driveLetter = base[0];

    No colon is inserted anywhere. Storing a bare "D" therefore builds the
    RELATIVE path "D\Hedz\..." which resolves against the current directory
    instead of the CD. A Process Monitor trace of the real game shows exactly
    that:

        CreateFile  C:\Games\HEDZ\D\Hedz\test        -> PATH NOT FOUND
        CreateFile  C:\Games\HEDZ\D\Hedz\Music\1.MUS -> PATH NOT FOUND

    (note the game's own folder prefixed onto the path). Storing "D:" yields
    the correct absolute "D:\Hedz\Music\1.MUS".

    If the entry is missing the game prints
    "Registry Entry Not found, full protection" and demands the CD.

    64-bit Windows trap: a 32-bit game reads the 32-bit registry view
    (HKLM\SOFTWARE\WOW6432Node\...). Importing a .reg file with a 64-bit
    reg.exe writes the 64-bit view instead, where the game never looks.
    This script writes the 32-bit view explicitly (and mirrors it).

.PARAMETER CdDrive
    Drive letter of the mounted HEDZ CD/image. "D:" and "D" both accepted.

.PARAMETER InstallDir
    Game folder (used only for the proxy audit and reporting).

.PARAMETER Language
    Language string the installer would have written (default English).

.PARAMETER InstallType
    Optional. Only written if you pass it (the game may expect it; try
    e.g. -InstallType 1 or -InstallType Full if the CD prompt persists).

.PARAMETER TrailingBackslash
    Store "D:\" instead of "D:". Both build a valid absolute path (the game
    appends "\Hedz\", so this form yields a harmless doubled separator); the
    default "D:" produces the cleaner path.

.PARAMETER CleanLegacy
    Removes the bogus "CDrive"/"InstallPath" values a previous manual
    import may have left behind (they are not real installer values).

.EXAMPLE
    # from an ELEVATED PowerShell (HKLM write):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Set-HedzCdPath.ps1 -CdDrive D:
#>
[CmdletBinding()]
param(
    [string]$CdDrive = 'D:',
    [string]$InstallDir = 'C:\GAMES\HEDZ',
    [string]$Language = 'English',
    [string]$InstallType = '',
    [switch]$TrailingBackslash,
    [switch]$CleanLegacy
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- normalise the drive letter ----
$letter = $CdDrive.Trim().TrimEnd('\').TrimEnd(':').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "CdDrive must be a drive letter like D: (got '$CdDrive')" }

# The game builds its CD path as:  <this value> + "\Hedz\"  and takes the
# first character as the drive letter. The colon MUST be part of the value.
$driveValue = if ($TrailingBackslash) { "${letter}:\" } else { "${letter}:" }

Write-Host '=== HEDZ CD-path registry fix ===' -ForegroundColor Cyan
Write-Host ("CD drive letter : {0}  (stored as '{1}')" -f $letter, $driveValue)
if (-not (Require-Admin)) {
    Write-Host ''
    Write-Host 'NOT ELEVATED - HKLM cannot be written from this shell.' -ForegroundColor Red
    Write-Host 'Re-run from an elevated PowerShell, e.g.:'
    Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -CdDrive {1}' -f $PSCommandPath, $CdDrive)
    exit 1
}

$relPath = 'SOFTWARE\Vis Interactive\Hedz'
$written = @()

# ---- write BOTH views; the 32-bit view is the one the game reads ----
foreach ($view in @(
        @{ name = '32-bit (game reads this)'; value = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ name = '64-bit (mirror)';          value = [Microsoft.Win32.RegistryView]::Registry64 })) {

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view.value)
    $key = $base.CreateSubKey($relPath, $true)
    if (-not $key) { Write-Warning ("Could not open HKLM\{0} [{1}]" -f $relPath, $view.name); $base.Close(); continue }

    $key.SetValue('InstalledFromDrive', $driveValue, [Microsoft.Win32.RegistryValueKind]::String)
    if (-not [string]::IsNullOrEmpty($Language)) {
        $key.SetValue('Language', $Language, [Microsoft.Win32.RegistryValueKind]::String)
    }
    if (-not [string]::IsNullOrEmpty($InstallType)) {
        $key.SetValue('InstallType', $InstallType, [Microsoft.Win32.RegistryValueKind]::String)
    }
    if ($CleanLegacy) {
        foreach ($bogus in 'CDrive', 'InstallPath') {
            if ($key.GetValueNames() -contains $bogus) { $key.DeleteValue($bogus, $false) }
        }
    }

    Write-Host ''
    Write-Host ("HKLM\{0}  [{1}]" -f $relPath, $view.name) -ForegroundColor Green
    foreach ($n in $key.GetValueNames()) {
        Write-Host ("    {0,-20} = {1}" -f $n, $key.GetValue($n))
    }
    $written += ("{0}:{1}" -f $view.name, $key.GetValue('InstalledFromDrive'))
    $key.Close()
    $base.Close()
}

# ---- verify the CD actually looks right on that letter ----
Write-Host ''
Write-Host 'CD verification:' -ForegroundColor Cyan
$root = "${letter}:\"
$devId = "${letter}:"
$vol = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $devId }
if ($vol) {
    Write-Host ("  {0} label='{1}' type={2} size={3:N0}" -f $vol.DeviceID, $vol.VolumeName, $vol.DriveType, $vol.Size)
    if ($vol.DriveType -ne 5) { Write-Host '  WARNING: this drive is not reported as a CD-ROM (DriveType 5).' -ForegroundColor Yellow }
} else {
    Write-Host ("  No drive at {0} - mount the HEDZ image first!" -f $root) -ForegroundColor Red
}
foreach ($probe in "HEDZ\HEDZ.EXE", "HEDZ\MUSIC", "HEDZ\MUSIC\1.MUS", "HEDZ\MOVIES", "SETUP.EXE") {
    $p = Join-Path $root $probe
    if (Test-Path $p) { Write-Host ("  [ok]   {0}" -f $probe) }
    else               { Write-Host ("  [MISS] {0}" -f $probe) -ForegroundColor Yellow }
}

# ---- audit a half-deployed winmm proxy ----
Write-Host ''
Write-Host 'winmm proxy audit:' -ForegroundColor Cyan
$proxy = Join-Path $InstallDir 'winmm.dll'
$real  = Join-Path $InstallDir 'winmm_real.dll'
if (Test-Path $proxy) {
    if (Test-Path $real) {
        Write-Host '  both winmm.dll and winmm_real.dll are present.'
        Write-Host '  NOTE: Hedz.exe contains no MCI/cdaudio code (its strings show'
        Write-Host '  DirectSound + Miles/AIL only). The proxy is not needed for this'
        Write-Host '  title and should be REMOVED unless you have evidence it helps:' -ForegroundColor Yellow
        Write-Host ('    Remove-Item "{0}","{1}"' -f $proxy, $real)
    } else {
        Write-Host '  winmm.dll present but winmm_real.dll MISSING.' -ForegroundColor Red
        Write-Host '  The proxy is non-functional in this state: its forwarded exports'
        Write-Host '  (timeGetTime, waveOut*, ...) have no target, so any module that'
        Write-Host '  imports them from winmm (Miles Sound System MSS32.DLL does) can'
        Write-Host '  fail to load or silently fall back - which can break audio/music.'
        Write-Host ('    Remove-Item "{0}"' -f $proxy) -ForegroundColor Yellow
    }
} else {
    Write-Host '  no winmm.dll in the game folder (correct baseline).'
}

Write-Host ''
Write-Host ("Next: launch {0}\Hedz.exe with the HEDZ image mounted on {1}: - " -f $InstallDir, $letter)
Write-Host 'music should stream from <CD>:\HEDZ\MUSIC once the game passes its disc check.'
