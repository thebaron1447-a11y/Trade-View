# Phase 3A: Deterministic matching and the Code Follow-Up list

Extract this zip into `C:\dev\trade-import-demo`, letting it overwrite. Run everything from that folder.

What this adds:
- Every staged row is now **matched** automatically right after staging: firm (alias or close spelling),
  rep code, the advisor(s) holding that code on the trade date, and the fund.
- Rows end up **Matched**, **Needs Review** (a person must choose), **Held** (waiting on missing code
  information) or **Invalid** (bad data from phase 2 validation).
- Held rows raise a **Code Follow-Up**: one to-do per firm, code and reason, with how many rows and dollars
  are waiting. Resolving it re-matches the held rows automatically.
- Trade files can now carry **AUM rows** mixed in with trades, and a separate **advisor code roster** feed
  is staged and classified (approving roster changes comes in phase 3B).

No Claude calls yet. Everything here is rule-based, so it is predictable and testable. Claude arrives in 3B
for the rows that rules cannot settle.

## 1. Validate (compiles, runs this project's 11 test classes, then rolls back)

```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests CsvParserTest --tests DemoScenarioTest --tests ImportBatchProcessorTest --tests MappingServiceTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only if this reports `Status: Succeeded` with all tests passing. If anything fails, send the full output.

## 2. Deploy, then refresh the mapping profiles

```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests CsvParserTest --tests DemoScenarioTest --tests ImportBatchProcessorTest --tests MappingServiceTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo
```

The seed script updates the three existing profiles (Barder's export now has a Record Type column; AUM indicator
values are set) and creates one new profile for the Barder advisor code roster. Expect 1 created, 3 updated.

## 3. Clear the phase 2 imports

The phase 2 batches were staged before matching existed. Delete them so the samples can be pushed fresh:

```powershell
sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
```

## 4. Push the sample trade files

Windows blocks scripts extracted from a downloaded zip. Unblock this one once (it affects only this file):

```powershell
Unblock-File -Path .\scripts\reset-demo.ps1
.\scripts\reset-demo.ps1
cd pushjob
.venv\Scripts\Activate.ps1
python push_job.py --lake ..\datalake --once --auth sfcli --target-org tradeDemo
cd ..
```

Expected: four `SENT` lines. Staging and matching run as two background jobs; wait about 30 seconds.

## 5. Check the results

```powershell
sf data query --query "SELECT Source_Firm__c, Status__c, Row_Count__c, Matched_Row_Count__c, Review_Row_Count__c, Held_Row_Count__c, Error_Row_Count__c FROM Import_Batch__c ORDER BY Source_Firm__c" --target-org tradeDemo
```

| Firm | Status | Rows | Matched | Review | Held | Invalid |
|---|---|---|---|---|---|---|
| BARDER | Pending Review | 10 | 5 | 1 | 3 | 1 |
| KESTREL | Mapping Review | 2 | 0 | 0 | 0 | 0 |
| LUMIERE | Pending Review | 5 | 5 | 0 | 0 | 0 |
| NORTHGATE | Pending Review | 11 | 5 | 0 | 4 | 2 |

Row by row:

```powershell
sf data query --query "SELECT Import_Batch__r.Source_Firm__c, Row_Number__c, Row_Type__c, Source_Rep_Code__c, Source_Advisor_Name__c, Match_Status__c, Credited_Advisor__r.Name, Matched_Fund__r.Name, Match_Flags__c FROM Import_Staging_Row__c ORDER BY Import_Batch__r.Source_Firm__c, Row_Number__c" --target-org tradeDemo
```

| Firm | Row | What is planted | Result | Flags |
|---|---|---|---|---|
| BARDER | 1-2 | "Barder and Co", "J. Morales", fund spelled 3 ways | Matched | |
| BARDER | 3 | Marcus Bell trades after 10 months quiet | Matched | DORMANT_CODE_REACTIVATED |
| BARDER | 4-5 | Priya Nair on Marcus Bell's code (nobody told us) | **Held** | REASSIGNMENT_SUSPECTED |
| BARDER | 6 | Fund name nobody has seen | Needs Review | FUND_UNRESOLVED |
| BARDER | 7 | Clean trade | Matched | |
| BARDER | 8 | No amount | Invalid | |
| BARDER | 9 | Code 3390 does not exist yet | **Held** | UNKNOWN_CODE |
| BARDER | 10 | AUM row mixed into the trade file | Matched | |
| NORTHGATE | 1-2 | Team code, one advisor named | Matched, 100% to that advisor | SINGLE_ADVISOR_CREDIT |
| NORTHGATE | 3, 11 | Dormant code, holder named (row 3 also has no firm name) | Matched | DORMANT_CODE_REACTIVATED |
| NORTHGATE | 4 | 2024 trade, while code 3102 was still active | Matched | |
| NORTHGATE | 5, 10 | No advisor named on team code 8800, whose split adds to less than 100% | **Held** | ALLOCATION_INCOMPLETE |
| NORTHGATE | 6-7 | Impossible date; SWITCH type | Invalid | |
| NORTHGATE | 8 | Code 3102 has since ended | **Held** | CODE_ENDED |
| NORTHGATE | 9 | Dormant code, no advisor named | **Held** | DORMANT_CODE_NO_NAME |
| LUMIERE | 1-2 | "Élise" vs "Elise", one advisor named on a team code | Matched | SINGLE_ADVISOR_CREDIT |
| LUMIERE | 3-5 | Both or neither advisor named | Matched | TEAM_SPLIT |

The follow-up to-do list:

```powershell
sf data query --query "SELECT Name, Rep_Code_Value__c, Reason__c, Status__c, Held_Row_Count__c, Held_Amount__c FROM Code_Follow_Up__c ORDER BY Name" --target-org tradeDemo
```

| Code | Reason | Rows | Amount |
|---|---|---|---|
| 2210 (Barder) | Reassignment Suspected | 2 | 280,000 |
| 3390 (Barder) | Unknown Code | 1 | 45,000 |
| 8800 (Northgate) | Allocation Incomplete | 2 | 1,200,000 |
| 3102 (Northgate) | Code Ended | 1 | 55,000 |
| 5521 (Northgate) | Code Dormant | 1 | 18,000 |

The amount counts trade rows only. The 8800 follow-up holds one trade and one AUM row, so it shows 2 rows but only
the trade's dollars. In the app, open **Code Follow-Ups** from the App Launcher (new tab, visible through the Trade Import Admin
permission set; pin it to your nav bar for the demo).

## 6. Demo: close the loop on a silent reassignment

This plays the part of Barder confirming that code 2210 moved from Marcus Bell to Priya Nair on 2026-09-15:

```powershell
sf apex run --file scripts/apex/demo-resolve-2210.apex --target-org tradeDemo
```

It ends Marcus Bell's assignment on 2026-09-14 (source: Confirmed by Firm), adds Priya Nair at 100% from
2026-09-15 and sets the follow-up to Resolved. Wait about 15 seconds and re-run the row query: Barder rows 4 and 5
are now **Matched**, credited to Priya Nair, and the follow-up shows 0 held rows.

You can do the same by hand in the UI: set any follow-up's Status to **Resolved** after fixing the code data, or to
**Closed - No Action** to send its rows to manual review instead. If you resolve one without fixing the data, the rows
are held again and the follow-up re-opens.

## 7. Optional: push the advisor code roster

```powershell
.\scripts\reset-demo.ps1 -Roster
cd pushjob
python push_job.py --lake ..\datalake --once --auth sfcli --target-org tradeDemo
cd ..
```

Expected: a Barder roster batch in Pending Review with 3 rows:

| Row | Roster says | Before step 6 | After step 6 |
|---|---|---|---|
| 1 | Julia Morales on 457 | Matched, ROSTER_CONFIRMS | same |
| 2 | Priya Nair on 2210 from 2026-09-15 | Needs Review, NEW_ADVISOR + ROSTER_NEW_HOLDER | Matched, ROSTER_CONFIRMS |
| 3 | Hannah Pierce on new code 3390 | Needs Review, NEW_ADVISOR + ROSTER_NEW_CODE | same |

Pushing the roster before step 6 shows the system spotting the reassignment from the roster itself. Phase 3B turns approval of these rows into new codes and assignments that resolve
the matching follow-ups.

## To run the demo again

```powershell
sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
```

then step 4. Note that step 6 changed code 2210's assignments; after it, Barder rows 4-5 will match straight away.
To restore the original state, reload the phase 1 seed data or end-date Priya's assignment and remove Marcus Bell's
end date by hand.

## Integration user note

The matching job runs as the user who pushed the file. The Trade Import Integration permission set now also grants
read access to Accounts, Contacts and Products (plus Parent Account and Contact's Account), because matching
reads firms, branches, advisors and funds in user mode. With `--auth sfcli` you are pushing as yourself, so this only
matters once a dedicated JWT integration user is used.

## Checks run before delivery

`tools/verify/check_vectors.py` re-runs the shared test vectors (now including advisor name matching) against the
Python port. The same vectors are compiled into NameMatcherTest. DemoScenarioTest asserts every row and follow-up in the
tables above.
