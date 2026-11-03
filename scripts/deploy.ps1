# Validates or deploys the project with every Apex test class, pausing the stranded work sweeper around it.
# Salesforce refuses to deploy Apex that a scheduled job depends on, and the sweeper reaches nearly every class, so
# its schedules are removed first and put back afterwards, whether the deploy passed or not.
# The test classes are found from the files (every class whose name ends in Test), so new ones are never missed.
#
# Run from the project folder:   .\scripts\deploy.ps1 -DryRun                (validate only; changes nothing)
#                                .\scripts\deploy.ps1                        (deploy)
#                                .\scripts\deploy.ps1 -TargetOrg myOrg       (another org alias)
param([string]$TargetOrg = 'tradeDemo', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$tests = Get-ChildItem 'force-app\main\default\classes\*Test.cls' | ForEach-Object { $_.BaseName } | Sort-Object
Write-Host "== $(if ($DryRun) { 'Validating' } else { 'Deploying' }) with $($tests.Count) test classes" -ForegroundColor Cyan

Write-Host '== Pausing the sweeper' -ForegroundColor Cyan
sf apex run --file scripts/apex/unschedule-sweeper.apex --target-org $TargetOrg
if ($LASTEXITCODE -ne 0) { throw 'Could not pause the sweeper, so nothing was deployed.' }

$deployArgs = @('project', 'deploy', 'start', '--source-dir', 'force-app', '--target-org', $TargetOrg, '--test-level', 'RunSpecifiedTests')
if ($DryRun) { $deployArgs += @('--dry-run', '--verbose') }
foreach ($t in $tests) { $deployArgs += @('--tests', $t) }

$result = 1
try {
    sf @deployArgs
    $result = $LASTEXITCODE
}
finally {
    Write-Host '== Restarting the sweeper' -ForegroundColor Cyan
    sf apex run --file scripts/apex/schedule-sweeper.apex --target-org $TargetOrg
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'The sweeper could not be restarted. Run scripts/apex/schedule-sweeper.apex by hand.' -ForegroundColor Yellow
    }
}
if ($result -eq 0) {
    Write-Host "== $(if ($DryRun) { 'Validation' } else { 'Deploy' }) succeeded" -ForegroundColor Green
}
else {
    Write-Host "== $(if ($DryRun) { 'Validation' } else { 'Deploy' }) failed (exit code $result). Send the output above." -ForegroundColor Red
}
exit $result
