param([string]$File)
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $File).Path, [ref]$null, [ref]$e) | Out-Null
if($e -and $e.Count){
    $e | ForEach-Object { Write-Host ("PARSE ERROR: {0}" -f $_.Message) }
    exit 1
} else {
    Write-Host ("parse OK: {0}" -f $File)
}
