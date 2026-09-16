#Requires -Version 5.1
<#
.SYNOPSIS
    Inspect-Wrapper.ps1 - identify the DirectDraw wrapper actually deployed in
    the game folder.

.DESCRIPTION
    A wrapper with the wrong build, the wrong bitness, or no config file next
    to it produces exactly the observed failure: the disc check passes, the
    screen goes black, and the process exits cleanly. This dumps, for every
    candidate wrapper DLL in the game folder:

      * SHA-256, size, PE machine type (x86 vs x64), DLL characteristics
      * version resource fields (ProductName/FileDescription identify the tool)
      * exported functions (and whether the real DirectDraw API set is there)
      * imported DLLs
      * tell-tale strings ("pal-ddraw", "DDrawCompat", "dgVoodoo", "wined3d",
        "SetEntries", "palette", ...)

    Nothing is modified - read-only inspection.
#>
[CmdletBinding()]
param(
    [string]$GameDir = 'C:\GAMES\HEDZ'
)

$ErrorActionPreference = 'Continue'

$candidates = @(
    'ddraw.dll', 'D3D8.dll', 'D3D9.dll', 'd3dimm.dll', 'DCIMAN32.dll',
    'dgVoodoo.dll', 'dgVoodoo2.dll', 'wined3d.dll', 'libwine.dll',
    'dinput.dll', 'dsound.dll'
)

function Get-PeInfo {
    param([byte[]]$b)
    $info = [ordered]@{ Machine = 0; MachineName = '?'; IsDll = $false; Chars = 0; Sections = @(); TimeDateStamp = 0 }
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return [pscustomobject]$info }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -lt 0 -or $pe + 24 -ge $b.Length) { return [pscustomobject]$info }
    if ($b[$pe] -ne 0x50 -or $b[$pe + 1] -ne 0x45) { return [pscustomobject]$info }   # 'PE'
    $info.TimeDateStamp = [BitConverter]::ToUInt32($b, $pe + 8)
    $info.Machine = [BitConverter]::ToUInt16($b, $pe + 4)
    $chars = [BitConverter]::ToUInt16($b, $pe + 22)
    $info.Chars = $chars
    $info.IsDll = (($chars -band 0x2000) -ne 0)
    $info.MachineName = switch ($info.Machine) {
        0x014C { 'x86 (32-bit) - required for a 32-bit game' }
        0x8664 { 'x64 - WRONG for this game' }
        0x01C0 { 'ARM' }
        0xAA64 { 'ARM64' }
        default { ('unknown 0x{0:X4}' -f $info.Machine) }
    }
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $secTab = $pe + 24 + $optSize
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $secTab + 40 * $i
        if ($o + 40 -gt $b.Length) { break }
        $nm = [Text.Encoding]::ASCII.GetString($b, $o, 8).Trim([char]0)
        $info.Sections += [pscustomobject]@{
            Name = $nm
            RAddr = [BitConverter]::ToUInt32($b, $o + 20)
            RSize = [BitConverter]::ToUInt32($b, $o + 16)
        }
    }
    return [pscustomobject]$info
}

function Get-PeExports {
    param([byte[]]$b)
    $names = New-Object System.Collections.Generic.List[string]
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt = $pe + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $dd = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $expRva = [BitConverter]::ToUInt32($b, $dd)
    if ($expRva -eq 0) { return $names }
    $secTab = $opt + $optSize
    $r2o = { param($rva)
        for ($i = 0; $i -lt $nsec; $i++) {
            $s = $secTab + 40 * $i
            $vs = [BitConverter]::ToUInt32($b, $s + 8)
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $pr = [BitConverter]::ToUInt32($b, $s + 20)
            if ($rva -ge $va -and $rva -lt ($va + [Math]::Max($vs, 1))) { return ($rva - $va + $pr) }
        }
        return -1
    }
    $e = & $r2o $expRva
    if ($e -lt 0) { return $names }
    $numNames = [BitConverter]::ToUInt32($b, $e + 24)
    $namesRva = [BitConverter]::ToUInt32($b, $e + 32)
    $nOff = & $r2o $namesRva
    if ($nOff -lt 0) { return $names }
    for ($i = 0; $i -lt $numNames; $i++) {
        $nRva = [BitConverter]::ToUInt32($b, $nOff + 4 * $i)
        $o = & $r2o $nRva
        if ($o -lt 0) { continue }
        $end = $o; while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        $names.Add([Text.Encoding]::ASCII.GetString($b, $o, $end - $o))
    }
    return $names
}

function Get-ImportedDlls {
    param([byte[]]$b)
    $out = New-Object System.Collections.Generic.List[string]
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt = $pe + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $dd = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }
    $impRva = [BitConverter]::ToUInt32($b, $dd + 8)
    if ($impRva -eq 0) { return $out }
    $secTab = $opt + $optSize
    $r2o = { param($rva)
        for ($i = 0; $i -lt $nsec; $i++) {
            $s = $secTab + 40 * $i
            $vs = [BitConverter]::ToUInt32($b, $s + 8)
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $pr = [BitConverter]::ToUInt32($b, $s + 20)
            if ($rva -ge $va -and $rva -lt ($va + [Math]::Max($vs, 1))) { return ($rva - $va + $pr) }
        }
        return -1
    }
    $p = & $r2o $impRva
    if ($p -lt 0) { return $out }
    while ($true) {
        $nameRva = [BitConverter]::ToUInt32($b, $p + 12)
        $oft = [BitConverter]::ToUInt32($b, $p); $ft = [BitConverter]::ToUInt32($b, $p + 16)
        if ($nameRva -eq 0 -and $oft -eq 0 -and $ft -eq 0) { break }
        if ($nameRva -ne 0) {
            $np = & $r2o $nameRva
            if ($np -ge 0) {
                $end = $np; while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
                $out.Add([Text.Encoding]::ASCII.GetString($b, $np, $end - $np))
            }
        }
        $p += 20
        if ($out.Count -gt 200) { break }
    }
    return $out
}

$markers = @('pal-ddraw', 'paldraw', 'DDrawCompat', 'dgVoodoo', 'wined3d', 'WineD3D', 'libwine',
             'SetEntries', 'SetPalette', 'GetDeviceIdentifier', 'DirectDrawCreateEx',
             'palette', 'd3d9', 'D3D9', 'd3d8', 'DDRAW.ini', 'ddraw.ini', 'compat')

Write-Host "=== wrapper inspection: $GameDir ===" -ForegroundColor Cyan
$any = $false
foreach ($n in $candidates) {
    $p = Join-Path $GameDir $n
    if (-not (Test-Path $p)) { continue }
    $any = $true
    $i = Get-Item $p
    $b = [IO.File]::ReadAllBytes($p)
    $pe = Get-PeInfo $b
    $hash = (Get-FileHash $p -Algorithm SHA256).Hash

    Write-Host ''
    Write-Host ("--- {0}  ({1:N0} bytes) ---" -f $n, $i.Length) -ForegroundColor Yellow
    Write-Host ("    sha256      : {0}" -f $hash)
    Write-Host ("    machine     : {0}" -f $pe.MachineName)
    Write-Host ("    is DLL      : {0}" -f $pe.IsDll)
    if ($pe.TimeDateStamp) {
        try { Write-Host ("    link date   : {0}" -f ([DateTimeOffset]::FromUnixTimeSeconds($pe.TimeDateStamp).UtcDateTime.ToString('yyyy-MM-dd'))) } catch {}
    }
    try {
        $vi = $i.VersionInfo
        $printed = $false
        foreach ($f in 'CompanyName', 'ProductName', 'FileDescription', 'FileVersion', 'OriginalFilename') {
            if ($vi.$f) { Write-Host ("    {0,-12}: {1}" -f $f, $vi.$f); $printed = $true }
        }
        if (-not $printed) { Write-Host '    version res : (NONE - no version resource at all)' -ForegroundColor Red }
    } catch { Write-Host '    version res : (unreadable)' }

    $exp = Get-PeExports $b
    Write-Host ("    exports     : {0}" -f $exp.Count)
    if ($exp.Count) {
        $show = $exp | Select-Object -First 14
        Write-Host ("      {0}{1}" -f ($show -join ', '), $(if ($exp.Count -gt 14) { ', ...' } else { '' }))
        foreach ($need in 'DirectDrawCreate', 'DirectDrawCreateEx', 'DirectDrawEnumerateExA') {
            if ($exp -contains $need) { Write-Host ("      [ok] exports {0}" -f $need) }
            elseif ($need -eq 'DirectDrawCreate') { Write-Host ("      [!!] does NOT export {0}" -f $need) -ForegroundColor Red }
        }
    }
    $imp = Get-ImportedDlls $b
    if ($imp.Count) { Write-Host ("    imports     : {0}" -f ($imp -join ', ')) }

    $s = [Text.Encoding]::GetEncoding(28591).GetString($b)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($m in $markers) { if ($s.IndexOf($m) -ge 0) { $hits.Add($m) } }
    if ($hits.Count) { Write-Host ("    markers     : {0}" -f ($hits -join ', ')) -ForegroundColor Green }
    else { Write-Host '    markers     : (none of the known wrapper markers found)' -ForegroundColor Red }
}

if (-not $any) { Write-Host '  no wrapper DLLs found in the game folder.' -ForegroundColor Yellow }

Write-Host ''
Write-Host '=== config files a wrapper would look for ===' -ForegroundColor Cyan
foreach ($n in 'ddraw.ini', 'DDRAW.ini', 'DDrawCompat.ini', 'DDrawCompat', 'dgVoodoo.conf', 'dgVoodoo2.conf') {
    $p = Join-Path $GameDir $n
    if (Test-Path $p) { Write-Host ("  [present] {0}" -f $n) -ForegroundColor Green }
    else { Write-Host ("  [absent ] {0}" -f $n) -ForegroundColor DarkGray }
}
