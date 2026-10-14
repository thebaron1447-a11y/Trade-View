# Copies the sample trade files back into the data lake inbox so the demo can be run again.
# Run from the project folder:  .\scripts\reset-demo.ps1            (trade files only)
#                               .\scripts\reset-demo.ps1 -Roster    (the advisor code roster file only)
# To clear previous imports from the org first, run scripts/apex/reset-imports.apex.
param([switch]$Roster)
$root = Split-Path -Parent $PSScriptRoot
$source = if ($Roster) { Join-Path $root 'datalake\samples\roster' } else { Join-Path $root 'datalake\samples\inbox' }
$inbox = Join-Path $root 'datalake\inbox'
Get-ChildItem -Path $source -Directory | ForEach-Object {
    $target = Join-Path $inbox $_.Name
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $_.FullName '*') -Destination $target -Force
    Write-Host ("Copied " + $_.Name + " files to " + $target)
}
