# Phase 3B: Claude suggestions, review decisions, roster approval, mapping proposals

Extract this zip into `C:\dev\trade-import-demo`, letting it overwrite. Run everything from that folder.

What this adds:
- **Claude suggests, a person decides.** After every matching run, Claude (Sonnet 5 through the Models API, so
  through the Einstein Trust Layer) looks at rows in Needs Review and open Code Follow-Ups. It suggests a firm,
  fund or advisor, with a confidence and a plain-language reason. Suggestions go in AI fields only. Nothing is matched
  until a reviewer sets **Reviewer Decision = Accept**.
- **Claude can only choose from what it was given.** It sees short keys (F1, P2, A3), never Salesforce Ids. Any
  answer naming something it was not offered is thrown away and logged.
- **Every call is audited** in **AI Request Logs**: the exact prompt, the raw answer, the model, how long it took
  and whether it passed validation.
- **Accepting a roster row** sets up the advisor, code and assignment, ends the old holder's share and resolves the
  matching follow-up, which releases its held trades.
- **Unknown file layouts** (Kestrel) get a Claude-proposed mapping, saved as a Draft. Setting it to Active
  processes the waiting file automatically.
- **Matching Rules** let reviewers teach firm conventions in plain language. Active rules are sent to Claude, and a
  second person must activate them.
- New tabs: Import Batches, Import Staging Rows (with a **Needs Review** list view), Mapping Profiles, AI Request
  Logs, Matching Rules.

## 1. Validate (compiles, runs this project's 19 test classes, then rolls back)

```powershell
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only if this reports `Status: Succeeded` with all tests passing. If anything fails, send the full output.
The tests never call Claude: a fake stands in for it, so the dry run uses no Einstein Requests.

## 2. Deploy and clear the old imports

```powershell
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests AiSettingsTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
```

The mapping profiles from 3A are unchanged, so there is no need to re-seed them.

Your org remembers the 2210 demo from 3A: Priya Nair already holds code 2210. So in this run, Barder rows 4 and 5 match
straight away, and there is no 2210 follow-up.

## 3. Push the roster first, then the trade files

The roster goes first so Claude can use it as evidence when it looks at the 3390 follow-up.

```powershell
Unblock-File -Path .\scripts\reset-demo.ps1
.\scripts\reset-demo.ps1 -Roster
cd pushjob
.venv\Scripts\Activate.ps1
python push_job.py --lake ..\datalake --once --auth sfcli --target-org tradeDemo
cd ..
```

Wait about 30 seconds, then:

```powershell
.\scripts\reset-demo.ps1
cd pushjob
python push_job.py --lake ..\datalake --once --auth sfcli --target-org tradeDemo
cd ..
```

Staging, matching and Claude now run one after another in the background. Give it **one to two minutes**: each Claude
request takes several seconds.

## 4. See what Claude did

```powershell
sf data query --query "SELECT Name, Purpose__c, Status__c, Item_Count__c, Duration_Ms__c, Error_Message__c FROM AI_Request_Log__c ORDER BY Name" --target-org tradeDemo
sf data query --query "SELECT Import_Batch__r.Source_Firm__c, Row_Number__c, Row_Type__c, Source_Advisor_Name__c, Match_Flags__c, AI_Status__c, AI_Confidence__c, AI_Suggested_Firm__r.Name, AI_Suggested_Fund__r.Name, AI_Suggestion__c FROM Import_Staging_Row__c WHERE Match_Status__c = 'Needs Review' ORDER BY Import_Batch__r.Source_Firm__c, Row_Number__c" --target-org tradeDemo
sf data query --query "SELECT Rep_Code_Value__c, Reason__c, AI_Status__c, AI_Confidence__c, AI_Suggested_Advisor__r.Name, Suggested_Resolution__c FROM Code_Follow_Up__c ORDER BY Name" --target-org tradeDemo
```

In the app, the same information is on the **Import Staging Rows > Needs Review** list view, in the **Claude** section of
each row and follow-up, and in **AI Request Logs**.

Claude's wording varies from run to run. What to look for:

| Item | What a good answer looks like |
|---|---|
| Barder row 6, fund "ETF Wealth World Fund A" | Low or Medium confidence. It could be the ETF or Series A; a careful answer says so rather than guessing |
| Barder roster: Hannah Pierce on 3390 | Recommends approving: a new advisor on a new code, branch given |
| Follow-up 3390 (Unknown Code) | Points to the roster row listing Hannah Pierce from 2026-09-20 |
| Follow-up 8800 (Allocation Incomplete) | Explains that the team split is short of 100% and must be fixed by hand |
| Every log | Status Success. If one says Invalid Response, its Error Message shows exactly what was rejected and why |

## 5. Kestrel: Claude proposes the mapping

The Kestrel batch is in Mapping Review, and there is a new profile named **KESTREL - proposed by Claude (date)** with
Status Draft.

1. Open it from **Mapping Profiles** and read **AI Rationale**. It should end with "Checks passed".
2. Set **Status** to **Active** and save. The waiting Kestrel file is processed automatically.
3. After a minute, both Kestrel rows are in **Needs Review** with FIRM_AMBIGUOUS: "Kestrel Capital" fits both
   Kestrel Capital Inc. and Kestrel Capital Ltd.
4. Claude should suggest **Inc.** for Ryan Chen (Calgary branch) and **Ltd.** for Megan Chen (Vancouver branch).
   It tells them apart by advisor, not by name.

## 6. Make the decisions

On each row (record page, **Review** section), set **Reviewer Decision**:

| Row | Decision | Result after re-matching |
|---|---|---|
| Kestrel row 1 (Ryan Chen) | Accept | Matched, credited to Ryan Chen, Match Method **Claude** |
| Kestrel row 2 (Megan Chen) | Accept | Matched, credited to Megan Chen |
| Barder row 6 | Pick **Fund Override** yourself, tick **Remember Choice**, then Accept | Matched, Match Method **Reviewer**. A new Fund Alias means the next file matches this spelling on its own |
| Roster: Hannah Pierce, 3390 | Accept | Hannah Pierce created at Oakville, code 3390 set up, the 3390 follow-up **Resolved**, and Barder row 9 re-matched to her |

Accept with no firm or fund to apply is refused with a message. So is deciding a row that is not in Needs Review.
**Reject** marks a row Rejected so it is never loaded. Who decided, and when, is stamped on the row.

To check afterwards:

```powershell
sf data query --query "SELECT Import_Batch__r.Source_Firm__c, Row_Number__c, Match_Status__c, Match_Method__c, Credited_Advisor__r.Name, Match_Flags__c, Decided_By__r.Name FROM Import_Staging_Row__c WHERE Reviewer_Decision__c != null ORDER BY Import_Batch__r.Source_Firm__c, Row_Number__c" --target-org tradeDemo
```

## 7. Optional: teach a matching rule

Create a **Matching Rule**, for example *Firm: Barder & Company, Rule: "Barder writes ETF fund names with a leading
ETF, for example ETF Wealth World Fund A means the Wealth World ETF."*, with Status **Proposed**.

Activating it needs a second person. If you try yourself, you will see "Someone other than the rule's author must activate
it". To demo alone, turn off **Require Two-Person Rule Approval** in Setup > Custom Metadata Types > Trade AI Setting >
Default. That setting is there for a demo org only. Once the rule is Active, it is included in every request to Claude.

## Settings

Setup > Custom Metadata Types > **Trade AI Setting** > **Default**:

| Setting | Default | Purpose |
|---|---|---|
| Enabled | checked | Untick to stop all Claude calls; everything else keeps working |
| Model Name | sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet | Any model your org lists, for example the Haiku 4.5 name for cheaper runs |
| Max Items Per Request | 10 | Items per Claude request (capped at 25) |
| Require Two-Person Rule Approval | checked | Rule activation needs a second person |

## To run the demo again

```powershell
sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
```

This now also deletes AI Request Logs and Claude-proposed profiles, so Kestrel gets a fresh proposal. Approvals stay:
Hannah Pierce, code 3390 and any taught aliases remain. To ask Claude again about items whose suggestion failed:

```powershell
sf apex run --file scripts/apex/request-suggestions.apex --target-org tradeDemo
```

## Limits and notes

- Claude runs in background jobs. A Developer Edition org allows a chain of five jobs, which covers this demo. If a
  chain stops early, the remaining items keep a blank AI Status and `request-suggestions.apex` picks them up.
- Each request includes the firms, funds and nearby advisors. Fine for this demo; a large org would send only the
  candidates for each item.
- The push job runs as your user (`--auth sfcli`), which can call the Models API. A dedicated integration user would
  also need the org's generative AI permission.
- `tools/verify/check_claude_vectors.py` re-runs the response-validation cases. The same cases are compiled into
  ClaudeValidationVectorTest.
