# Phase 4e: loading approved rows, notifications and holder confirmation

**Update 4e.2 (notifications and holder confirmation):** see section 24 of the build log.
- **Trade Review updates itself when background work finishes.** Reading a file, matching, Claude's answers and each
  load step publish a *Trade View Update* platform event. The page listens for it and refreshes, so it no longer checks
  every 5 seconds. It still checks every 30 seconds while something is running, in case an update is missed, and goes
  back to 5 seconds where it can't listen.
- **A bell for the person waiting.** Whoever uploads a file in the app or clicks Load file gets a Salesforce
  notification when the file is matched, needs a mapping, fails, is booked, is part loaded or stops loading. It opens
  Trade Review. Files from the push job notify nobody.
- **Confirm holder** on a Code Dormant review: when the firm confirms the current holder still uses the code, this
  records it on the assignment (Holder Confirmed On and By), so the code stops counting as dormant, and re-matches the
  held rows, which are then credited as usual.

New test classes TradeViewNotifierTest and HolderConfirmationTest: **29 classes, 206 tests**.

**From now on, validate and deploy with `scripts\deploy.ps1`.** It removes the sweeper's schedules, runs the deploy
with every test class in the folder (so the command never goes stale as classes are added), and puts the schedules
back afterwards, whether the deploy passed or not:

```powershell
.\scripts\deploy.ps1 -DryRun     # validate
.\scripts\deploy.ps1             # deploy
```

## Phase 4e.1: loading approved rows

Until now a file ended at "decided". This phase books it. **Load file** in Recent Files turns a file's matched rows
into the records the business reports on:

- a **Trade** row becomes a **Trade** with one **Trade Allocation** per credited advisor;
- an **AUM** row becomes an **AUM Balance** (new object) with one **AUM Allocation** (new object) per advisor.

Credit follows matching. If a row has a Credited Advisor, that advisor gets 100%. A team row splits by the shares
active on the row's date. Allocations always add up to the cent: each share is rounded towards zero, and the
leftover cents go to the largest share. Redemptions are negative, so summing allocations by advisor gives net sales.

Rows still in review or on hold stay in the file. Once they are decided, Load file appears again for them. When
nothing is left waiting, the file is **Completed**. See section 23 of the build log.

This deploy also carries **4b.8, the stranded-work sweeper** (section 22). It now also restarts a load left part way.

## What is new

| Part | What it does |
|---|---|
| Load file button | In Recent Files, on a file in Pending Review with matched rows not yet loaded: **Load N matched rows**. It runs in the background: the file shows *Loading* and the page refreshes itself until it finishes. |
| TradeLoader | Books the file 200 rows at a time. Each batch of 200 saves all or nothing. If one fails, the file goes back to Pending Review with the error shown on it, and nothing from that batch is saved. |
| TradeAllocator | Splits to the cent. For example, 60/40 of $1,000.01 gives $600.01 and $400.00. |
| No double booking | A Trade's Load Key is its row's Id, and that key is unique. An AUM Balance is keyed by code, fund (or ALL) and as-of date. A balance sent again replaces the earlier figure and its split. |
| Shares changed since matching | If a team's shares no longer total 100% on the row's date, the row is not booked. The same applies if a trade has lost its fund. Such a row goes back to Pending with a note, and matching puts it on hold or in review as it would a new row. |
| Booked rows are locked | Once loaded, a row's match can't change any more. Only a data fix (Trade Import Admin) can change it. |
| Tabs | **Trades** and **AUM Balances**, for reviewers and admins. Reviewers can read everything a load books and edit none of it. |
| Reset scripts | `reset-imports.apex` and `reset-reference-data.apex` delete trades, AUM balances and their allocations first. |

New fields: AUM Balance (Rep Code, Fund, As Of Date, Balance, Balance Key, Source Row); AUM Allocation (AUM Balance,
Advisor, Allocation Percent, Allocated Balance); Trade (Source Row, Load Key); Import Staging Row (Loaded At, Loaded
Trade, Loaded AUM Balance); Import Batch (Loaded Row Count). New validation rule: AUM Balance cannot be negative.

## 1. Validate (29 test classes, expect 206 tests)

**First, pause the sweeper.** Salesforce won't deploy Apex while a scheduled job depends on it, and the sweeper's
schedule reaches almost every class. Remove its four schedules, then put them back after the deploy (step 3.1):

```powershell
sf apex run --file scripts/apex/unschedule-sweeper.apex --target-org tradeDemo
```

The log should end with `Sweeper schedules left: 0`. Do this before every dry run and deploy from now on.


```powershell
cd C:\dev\trade-import-demo
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests FileIntakeServiceTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewControllerTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests SystemWriterTest --tests SecurityModelTest --tests StrandedWorkSweeperTest --tests TradeAllocatorTest --tests TradeLoaderTest --tests TradeViewNotifierTest --tests HolderConfirmationTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Only continue if the output ends in `Status: Succeeded`. If anything fails, send the full output. Two things are new
to the org and are the likeliest to need a tweak:

- the tab styles on the two new tabs (*Custom17: Sack* and *Custom16: Bank*);
- `TradeLoaderTest.aReviewerCanLoadAndSeeWhatWasBooked`, which loads a file as a Standard User holding only the
  Reviewer permission set.

## 2. Deploy

Run the same command without `--dry-run --verbose`.

## 3. Once after the deploy

1. **Schedule the sweeper again.** It replaces any earlier schedule:
   `sf apex run --file scripts/apex/schedule-sweeper.apex --target-org tradeDemo`. Setup → Scheduled Jobs should then
   show four *Trade View stranded work sweeper* jobs.
2. **Reset the demo.** Bookings from an older run can't exist yet, but the reset scripts now clear them:
   `.\scripts\reset-demo-full.ps1`.

## 4. Try it

Give the reset two minutes, then open Trade Review → **Recent Files**.

| Try | You should see |
|---|---|
| A file in Pending Review | **Load N matched rows** under its summary, and the note *Rows in review or on hold load later* if it has any |
| Click it | A toast *Loading N rows…*. The file shows *Loading*, then *Pending Review* (rows still waiting) or *Completed*, with *N loaded* in its summary |
| Trades tab | One trade per loaded Trade row, each with its Source Row, and Trade Allocations that add up to the Signed Amount |
| The Lumière file's 19 Sep trade on team code 7700 ($7,250.75, no advisor named) | Élise Gagnon 60% $4,350.45 and Marc-André Roy 40% $2,900.30. Its 30 Sep SOLDE row becomes one AUM Balance for all funds, split the same way |
| AUM Balances tab | One balance per code, fund and as-of date, split the same way |
| Decide a row in Needs Decision, then back to Recent Files | **Load 1 matched row** on that file again |
| Open a loaded staging row | *Loaded At*, *Loaded Trade* or *Loaded AUM Balance* in its Loaded section |

### Try 4e.2

| Try | You should see |
|---|---|
| Upload a file in Trade Review, then wait without clicking Refresh | The page updates on its own when the file is matched, and the bell shows *File ready: …* with its counts |
| Load file | The page updates when the load finishes; the bell says *File booked* (or *Rows loaded* if rows are still waiting) |
| Dealer Code Review → code 5521 (Northgate, Code Dormant) | **Confirm holder**, with *Use when the firm confirms Tom Reilly still uses code 5521* |
| Click it | The review closes as Resolved, the held row is matched again and credited to Tom Reilly, and Tom's assignment on 5521 shows Holder Confirmed On (today) and By (you) |

If no bell appears but the page still updates itself, check Setup → Notification Builder → Custom Notifications for
*Trade View* (desktop and mobile should be on).

## 5. Optional: run the LWC tests on your computer

```powershell
npm install
npm run test:unit
python tools\verify\lwc_xref.py force-app\main\default
```

62 Jest tests should pass across the three components.
