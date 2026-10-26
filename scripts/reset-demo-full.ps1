# Full demo reset: clears every import AND puts the reference data back exactly as seeded (rep codes, assignments,
# aliases, advisors), so every planted problem shows up again. Then pushes the roster file, waits, and pushes the
# trade files. Spellings taught by reviewers, advisors created by approving roster rows (Hannah Pierce, Priya Nair)
# and matching rules are removed. Firms, branches, funds and mapping profiles are kept.
#
# Run from the project folder:   .\scripts\reset-demo-full.ps1
#                                .\scripts\reset-demo-full.ps1 -NoPush            (reset only)
#                                .\scripts\reset-demo-full.ps1 -TargetOrg myOrg   (another org alias)
param([string]$TargetOrg = 'tradeDemo', [switch]$NoPush)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Step([string]$Label, [scriptblock]$Action) {
    Write-Host ''
    Write-Host "== $Label" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit code $LASTEXITCODE). Nothing after this step was run." }
}

Invoke-Step 'Clear imports, follow-ups and AI logs' { sf apex run --file scripts/apex/reset-imports.apex --target-org $TargetOrg }
Invoke-Step 'Restore the seeded reference data' { sf apex run --file scripts/apex/reset-reference-data.apex --target-org $TargetOrg }
Invoke-Step 'Make sure the mapping profiles are in place' { sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org $TargetOrg }
if ($NoPush) { Write-Host 'Reset done. Push the files when ready.'; return }

$python = Join-Path $root 'pushjob\.venv\Scripts\python.exe'
if (-not (Test-Path $python)) { throw "Push job environment not found at $python. Set it up as in PHASE2.md first." }
function Invoke-Push {
    Push-Location (Join-Path $root 'pushjob')
    try { & $python push_job.py --lake ..\datalake --once --auth sfcli --target-org $TargetOrg }
    finally { Pop-Location }
}

& (Join-Path $PSScriptRoot 'reset-demo.ps1') -Roster
Invoke-Step 'Push the advisor code roster' { Invoke-Push }
Write-Host 'Waiting 30 seconds so the roster is matched before the trade files arrive...'
Start-Sleep -Seconds 30
& (Join-Path $PSScriptRoot 'reset-demo.ps1')
Invoke-Step 'Push the trade files' { Invoke-Push }
Write-Host ''
Write-Host 'Done. Open Trade Review: items appear over the next one to two minutes.' -ForegroundColor Green
