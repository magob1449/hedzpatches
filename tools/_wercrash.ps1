$ErrorActionPreference='Continue'
Write-Host '=== last Hedz application errors (WER 1000/1001) ==='
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001; StartTime=(Get-Date).AddMinutes(-10)} -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'Hedz' } |
  Select-Object -First 3 | ForEach-Object {
    Write-Host ("--- {0}  event {1}" -f $_.TimeCreated, $_.Id)
    ($_.Message -split "`r?`n") | Select-Object -First 12 | ForEach-Object { Write-Host ("    {0}" -f $_) }
  }
Write-Host ''
Write-Host '=== dgVoodoo lines in debug capture ==='
$f = Join-Path $PSScriptRoot 'trace\debug-messages.txt'
if(Test-Path $f){
  $hits = Select-String -Path $f -Pattern 'dgVoodoo|dgvoodoo|DgVoodoo' -SimpleMatch:$false
  if($hits){ $hits | Select-Object -First 20 | ForEach-Object { Write-Host $_.Line } }
  else { Write-Host '(no dgVoodoo output captured)' }
} else { Write-Host '(no debug capture file)' }
