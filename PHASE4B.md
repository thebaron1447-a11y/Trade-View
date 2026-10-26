# Phase 4b: the Trade Review app

One tab, **Trade Review**, for everything that needs a person:

- **Needs Decision**: rows waiting for a person, grouped by file. Each shows what the file said, why it needs review in plain words,
  Claude's suggestion with its confidence, and the decision controls: firm, fund or advisor (prefilled with Claude's
  choice), *Remember this spelling*, **Accept** / **Approve roster entry**, **Reject**.
- **Code Review**: rep codes with a problem (issue type, held trades and amount, Claude's suggestion). Every trade on
  a code waits here until the code is fixed; Needs Decision shows how many. Resolve on the follow-up record.
- **New File Format**: files whose columns no mapping recognises, with Claude's proposal and **Activate mapping**.
- **Recent Files**: the last ten files and how their rows came out (including duplicates and damaged files).
- **Upload file**: drop in a dealer CSV (up to 1 MB). It goes through exactly the same steps as files from the lake.
- **Assign to me / Unassign** and the **All / Mine / Unassigned** filter, for teams. A single reviewer can ignore them.
- The page refreshes itself while files, matching or Claude are still working.

The app saves decisions to the same fields as the record page, so every rule, refusal and audit stamp is unchanged.

## 1. Validate (22 test classes, expect 134 tests)

```powershell
cd C:\dev\trade-import-demo
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests FileIntakeServiceTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewControllerTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only on `Status: Succeeded`. If anything fails, send the full output. The test most likely to need a tweak
is `ReviewControllerTest.theReviewerPermissionSetIsEnough`: it runs every reviewer action as a user holding only the
new permission set, so it is the one that proves the permissions are complete.

## 2. Deploy

The same command without `--dry-run --verbose`.

## 3. Open the app

App Launcher, search **Trade Review**. If the tab is not offered, refresh the browser once (new tabs are cached).

### Full demo reset: every planted problem, fresh

```powershell
.\scripts\reset-demo-full.ps1
```

This clears all imports, puts the rep codes, assignments, aliases and advisors back exactly as seeded (removing taught
spellings, Hannah Pierce, Priya Nair and matching rules), then pushes the roster, waits 30 seconds and pushes the trade
files. The push output shows one **DUPLICATE** (the Barder file sent twice). Give it two minutes, then open Trade Review.

What you should see:

| Tab | Items |
|---|---|
| Needs Decision | Barder: row 6 fund unknown, row 11 dated before the code started, row 12 fund could be Series A or F. Northgate: row 12 firm name unknown. Roster: Priya Nair as the new holder of 2210, Hannah Pierce on new code 3390 |
| Code Review | 2210 reassignment suspected, 3390 unknown code, 8800 team shares under 100%, 3102 code ended, 5521 dormant, 7700 someone not on the team |
| New File Format | Kestrel, with Claude's proposed mapping. After **Activate mapping**: three Kestrel rows in Needs Decision (two firm ambiguous, one with no firm name) |
| Recent Files | The damaged Northgate file, **Failed**, with the reason |

Suggested order for the demo: approve the roster rows first (watch 2210 and 3390 leave Code Review and their trades
match), then the fund and firm decisions, then activate Kestrel.

## 4. Optional: a reviewer who is not an admin

Assign **Trade Import Reviewer** to a second user. For Claude to run on their actions they also need the org's
generative AI permission set (Enterprise tier) or **Trade Import Anthropic API** (Standard tier).

```powershell
sf org assign permset --name Trade_Import_Reviewer --target-org tradeDemo --on-behalf-of <their username>
```

## 5. Optional: run the LWC tests on your computer

```powershell
npm install
npm run test:unit
python tools\verify\lwc_xref.py force-app\main\default
```

17 Jest tests should pass; `lwc_xref.py` checks every Apex call from the app passes exactly the parameter names
the Apex method expects.
