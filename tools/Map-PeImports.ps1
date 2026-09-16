<#
.SYNOPSIS
    Map-PeImports.ps1 - list every Import Address Table slot of a 32-bit PE
    with the address the game's disassembly uses for "call dword ptr ds:[XXXXh]".

.DESCRIPTION
    The disassembly shows calls as `call dword ptr ds:[004C0378h]`, which names
    the IAT slot, not the function. This walks the PE import directory and prints
    `<IAT VA> <DLL> <function>` so those slots can be resolved.

    Output columns: IATVA, DLL, Function. Also supports -Find <VA> to resolve one.

.PARAMETER Path
    Path to the PE file.

.PARAMETER Find
    Optional IAT virtual address to resolve, e.g. 0x4C0378.

.EXAMPLE
    .\Map-PeImports.ps1 -Path C:\GAMES\HEDZ\Hedz.exe -Find 0x4C0378
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Find
)

$ErrorActionPreference = 'Stop'

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))

function Get-U16([int]$o) { [BitConverter]::ToUInt16($bytes, $o) }
function Get-U32([int]$o) { [BitConverter]::ToUInt32($bytes, $o) }

if ((Get-U16 0) -ne 0x5A4D) { throw "Not an MZ executable: $Path" }
$peOff = Get-U32 0x3C
if ((Get-U32 $peOff) -ne 0x00004550) { throw "Not a PE file: $Path" }
$coff      = $peOff + 4
$numSec    = Get-U16 ($coff + 2)
$optSize   = Get-U16 ($coff + 16)
$opt       = $coff + 20
$magic     = Get-U16 $opt
$is64      = ($magic -eq 0x20B)
if ($is64) { throw "This is a 64-bit PE; the game is 32-bit." }

$imageBase = Get-U32 ($opt + 28)
$secAlign  = Get-U32 ($opt + 32)
$fileAlign = Get-U32 ($opt + 36)
# Data directories begin at offset 96 in the optional header for PE32.
$dirOff    = $opt + 96
$importRva = Get-U32 ($dirOff + 1 * 8)     # entry 1 = import table
$importSz  = Get-U32 ($dirOff + 1 * 8 + 4)

# Section table enables RVA -> file offset.
$secs = @()
$secOff = $opt + $optSize
for ($i = 0; $i -lt $numSec; $i++) {
    $b = $secOff + $i * 40
    $secs += [pscustomobject]@{
        Name    = ([Text.Encoding]::ASCII.GetString($bytes, $b, 8)).Trim([char]0)
        VSize   = Get-U32 ($b + 8)
        VAddr   = Get-U32 ($b + 12)
        RawSize = Get-U32 ($b + 16)
        RawPtr  = Get-U32 ($b + 20)
    }
}

function RvaToOff([uint32]$rva) {
    foreach ($s in $secs) {
        if ($rva -ge $s.VAddr -and $rva -lt ($s.VAddr + [Math]::Max($s.VSize, $s.RawSize))) {
            return [int]($rva - $s.VAddr + $s.RawPtr)
        }
    }
    return -1
}

function Read-CStr([int]$off) {
    if ($off -lt 0) { return '' }
    $sb = New-Object Text.StringBuilder
    while ($off -lt $bytes.Length) {
        $c = $bytes[$off]
        if ($c -eq 0) { break }
        [void]$sb.Append([char]$c)
        $off++
    }
    $sb.ToString()
}

$rows = New-Object Collections.Generic.List[object]
$d = RvaToOff $importRva
while ($true) {
    $oft  = Get-U32 $d
    $name = Get-U32 ($d + 12)
    $ft   = Get-U32 ($d + 16)
    if ($oft -eq 0 -and $name -eq 0 -and $ft -eq 0) { break }
    $dllName = Read-CStr (RvaToOff $name)
    $thunkOff = RvaToOff $oft
    if ($thunkOff -lt 0) { $thunkOff = RvaToOff $ft }
    $idx = 0
    while ($true) {
        $t = Get-U32 ($thunkOff + $idx * 4)
        if ($t -eq 0) { break }
        $slotVa = $imageBase + $ft + $idx * 4
        if ($t -band 0x80000000) {
            $fn = "Ordinal#$($t -band 0xFFFF)"
        } else {
            $fn = Read-CStr ((RvaToOff $t) + 2)
        }
        $rows.Add([pscustomobject]@{
            IATVA     = ('{0:X8}' -f $slotVa)
            DLL       = $dllName
            Function  = $fn
        })
        $idx++
    }
    $d += 20
}

if ($Find) {
    $want = ('{0:X8}' -f [uint32]([Convert]::ToUInt32($Find, 16)))
    $hit = $rows | Where-Object { $_.IATVA -eq $want }
    if (-not $hit) { Write-Host "No import at IAT VA $want" } else { $hit | Format-Table -AutoSize | Out-String | Write-Host }
    return
}

Write-Host ("imports: {0}  imagebase: {1:X8}" -f $rows.Count, $imageBase)
$rows | Sort-Object IATVA | Format-Table -AutoSize
