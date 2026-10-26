# Trade Import Reconciliation: project context

Paste or attach this file at the start of a new chat. It describes the project as of **2026-10-25**: what exists,
how it is built and checked, every decision made so far, and what comes next. The full history is in
`docs/Trade_Import_Build_Log.docx`, and each phase has a run guide (`PHASE1.md` to `PHASE4B2.md`).

---

## 1. Who and why

- **Owner:** Greg Baronian, Salesforce consultant (Platform App Builder certified, not Platform Developer).
  Background: 2.5 years on Financial Services Cloud in private wealth, previously a business systems analyst at a
  wealth manager.
- **Purpose:** a portfolio piece for Salesforce Solution Engineer and Anthropic Applied AI / Demo Engineer roles. It
  shows a realistic wealth-management back-office problem solved Salesforce-natively with Claude. It's meant to be
  shown to leadership at other companies, and Phase 5 adds a demo video.
- **All demo data is synthetic.** Every firm, advisor and fund is fictional.

## 2. Working agreements (follow these in every chat)

**Approach**
- Salesforce best practices, official documentation first.
- Challenge every answer before presenting it. Double-check all code before it goes to the org; it must pass the
  local checks in section 9.

**Format for field and variable definitions**
- Every custom field is presented as a block:
  `Name / API / Type / Description / Help` (Title Case label, API name within 40 characters, help text within 510).
- Every Flow variable is presented as a block:
  `API / Type / Default / Availability / Description`.

**Build log**
- Keep `docs/Trade_Import_Build_Log.docx` up to date with a section per phase: what it does, how it works,
  delivered components, field definitions generated from the metadata, verification, and known limitations.

**Secrets**
- Never commit `pushjob/keys/server.key`; `pushjob/keys/` is git-ignored.
- The Anthropic API key lives only on the External Credential principal in Setup. It never goes into code, files
  or chat.

**Deploy and git**
- Greg deploys and commits from PowerShell himself.
- The assistant's shell on his computer cannot delete files. Running git there would leave `.lock` files, so the
  assistant never runs git.

**Delivery**
- The assistant writes files directly into `C:\dev\trade-import-demo`, then confirms them with md5 checks.
- It gives Greg the dry-run command and the field definitions.
- Greg runs the dry run and pastes the output. The assistant fixes any failure from the real error message and
  never guesses.

**Getting test failures out of a run**
```powershell
(sf project deploy report --target-org tradeDemo --use-most-recent --json | ConvertFrom-Json).result.details.runTestResult.failures | Format-List name, methodName, message, stackTrace
```
(`deploy report` has no `--verbose` flag. `--use-most-recent` reports the last deploy, so start a new dry run before
re-checking.)

## 3. Environment

| Item | Value |
|---|---|
| Org | Developer Edition, alias `tradeDemo`, user `gregory.baron.f2cac6700e9c@agentforce.com` |
| Project | `C:\dev\trade-import-demo` (SFDX, metadata API v66.0) |
| Shell | PowerShell; Python venv for the push job at `pushjob\.venv` |
| Salesforce CLI | 2.132 (an update is available; not required) |
| Claude, Enterprise tier | Models API through the Einstein Trust Layer, model `sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet` |
| Claude, Standard tier | Anthropic Messages API, `callout:Anthropic_API/v1/messages`, model `claude-sonnet-5-5`, anthropic-version `2023-06-01` |

## 4. The solution in one paragraph

Dealers (other investment firms) send CSV files of trades, AUM and advisor rep-code rosters. Files arrive through:
- a **push job** (Python, REST endpoint `/services/apexrest/trade-import/v1/files`);
- an **upload** in the app;
- later, a **cloud storage pull** (phase 4c).

Every route goes through **FileIntakeService**, which runs a SHA-256 duplicate check and a 1 MB limit, then saves
the file to an **Import Batch** with a ContentVersion.

A **Mapping Profile**, recognised by a header fingerprint, maps the columns. Rows are normalised into **Import
Staging Rows**, then matched rule-first by **TradeMatcher**: firm, rep code, the advisor(s) on the trade date, and
the fund. Each row ends as **Matched**, **Needs Review**, **Held** (behind a **Code Follow-Up**) or **Invalid**.

**Claude** then suggests answers for the rows rules can't settle. It sees short keys only, and its answers are
validated strictly. It also proposes mapping profiles for unknown file formats and drafts follow-up emails to firms.

A person decides everything in the **Trade Review** app (an LWC on its own tab). Two tiers:
- **Enterprise** (the default): Models API and the Trust Layer.
- **Standard**: smaller firms use the Anthropic API with their own key, which also enables prompt caching.

Enterprises will almost never use the direct route, because of compliance mandates.

## 5. Phase history and status

| Phase | What | Status |
|---|---|---|
| 1 | Data model, seed data (firms, branches, advisors, funds, codes, aliases) | Deployed |
| 2 | Ingestion: REST endpoint, push job, CSV parser, mapping profiles, staging, validation | Deployed |
| 3A | Deterministic matching, Code Follow-Ups, AUM rows, roster feed | Deployed and verified 2026-10-14 |
| 3B (+3B.1, 3B.2) | Claude suggestions, review decisions, roster approval, mapping proposals, matching rules | Deployed, 110/110 tests, verified 2026-10-21 |
| 4a | Standard tier: Anthropic API provider, Named and External Credential | Dry run 118 tests 2026-10-21, deployed |
| 4b | Trade Review app, FileIntakeService, Reviewer permission set | Dry run 132 tests 2026-10-22, deployed |
| 4b.1a | Tab names, issue types, full demo reset, every problem planted in the samples | Built 2026-10-23 |
| 4b.2 | Root-cause headlines, Put on hold and On Hold tab, per-field Claude table, roster "Approving will" preview, firm follow-up email, token logging, prompt caching, label spacing fix | Dry run 145/145 2026-10-23 |
| 4b.2a | One shared table layout; code issues in Dealer Code Review; Email Firms tab | Dry run 146/146 2026-10-25 |
| 4b.3 | Rows sharing an issue (same spelling, same dealer, any file) shown as one line with count, total and files; one decision, hold or assignment applies to all (200 per click); one firm question per issue | Built 2026-10-25. **Dry run next (expect 151 tests)**; then full demo reset (keys are set when rows are matched) |
| 4c | Cloud storage pull: S3, Azure Blob, Google Cloud Storage | Next |
| 4d | Setup Assistant: a guided first-time configuration wizard covering manual upload, cloud pull and push agent | Planned |
| 4e | Confirm holder for dormant codes; guard against two suggestion jobs at once; load approved rows into Trade, Trade Allocation and AUM records; notifications | Planned |
| 5 | Demo video; JWT and External Client App setup for the push job | Planned |

**Still to do after the current deploy (4b.2 setup, from `PHASE4B2.md`):**
- Add Operations Contact to the Account page layout (standard object layouts aren't in the package).
- On Barder & Company and Northgate, set Operations Contact to a contact whose **email is Greg's own address**.
- In App Builder, put **AI Suggestion Table** on the Import Staging Row and Code Follow-Up record pages, and
  activate them as org default.
- Run `.\scripts\reset-demo-full.ps1` and walk through the app. The **Send Email window** is the one part not yet
  confirmed in the org. If its To, Subject or Body fields are blank, the likely cause is those fields being
  read-only on the Send Email global action layout.

## 6. Data model

Custom objects: Import_Batch__c (IB), Import_Staging_Row__c (SR), Mapping_Profile__c (MP), Code_Follow_Up__c (CF),
Rep_Code__c, Rep_Code_Assignment__c, Firm_Alias__c, Fund_Alias__c, AI_Request_Log__c (AL), Matching_Rule__c (MR),
Trade__c, Trade_Allocation__c. Custom metadata: Trade_AI_Setting__mdt (record `Default`).

Standard objects:
- **Account**: firms, with branches as child Accounts through ParentId. It has the custom field
  `Operations_Contact__c` (Lookup to Contact).
- **Contact**: advisors, linked through AccountId to a branch or firm.
- **Product2**: funds. A delete guard trigger protects funds that trades use.

**Key fields**
- **Import_Batch__c**
  - Source_Firm__c (dealer code, e.g. BARDER), Source_File_Name__c, File_Hash__c (SHA-256), Header_Fingerprint__c,
    Mapping_Profile__c.
  - Status__c: Received, Mapping Review, Processing, Staged, Pending Review, Approved, Loading, Completed, Rejected,
    Failed.
  - Row, matched, review, held and error counts; Error_Message__c.
- **Import_Staging_Row__c, source and matching**
  - Source fields: Source_Firm_Name__c, Source_Rep_Code__c, Source_Advisor_Name__c, Source_Branch_Name__c,
    Source_Fund_Name__c, Trade_Date__c, Transaction_Type__c (Purchase or Redemption), Amount__c, Raw_Data__c.
  - Row_Type__c: Trade, AUM or Code Roster.
  - Match_Status__c: Pending, Matched, Needs Review, Held, Invalid or Rejected.
  - Match_Flags__c (semicolon list), Match_Notes__c, Match_Method__c, Match_Candidates__c.
  - Matched_Firm__c, Matched_Fund__c, Matched_Rep_Code__c, Credited_Advisor__c, Code_Follow_Up__c.
- **Import_Staging_Row__c, review**
  - Reviewer_Decision__c (Accept or Reject), Firm_Override__c, Fund_Override__c, Remember_Choice__c, Decided_By__c,
    Decided_At__c, Assigned_To__c.
- **Import_Staging_Row__c, Claude**
  - AI_Status__c: Suggested, No Suggestion, Invalid or Failed.
  - AI_Confidence__c: High, Medium or Low.
  - AI_Suggestion__c (explanation), AI_Suggested_Firm__c, AI_Suggested_Fund__c, AI_Suggested_Advisor__c,
    AI_Request__c.
  - Added in 4b.3: Issue_Key__c Text(255), External ID (not unique): dealer + firm/fund issues + normalised spelling (+ rep code for missing or ambiguous names); blank for roster rows, code issues and rows not in review; SHA-256 hash if over 255 characters.
  - Added in 4b.2: AI_Headline__c Text(100); AI_Recommended_Action__c (Accept, Reject or Hold); AI_Homework__c
    LongText(1000); AI_Field_Suggestions__c LongText(5000), a JSON list of {field, value, confidence, reason}.
- **Import_Staging_Row__c, on hold (4b.2)**
  - On_Hold__c, On_Hold_Reason__c LongText(2000), On_Hold_By__c (User), On_Hold_Since__c, Asked_Firm_At__c.
- **Code_Follow_Up__c**
  - Rep_Code_Value__c, Firm__c, Rep_Code__c.
  - Reason__c: Unknown Code, Code Ended, Code Dormant, Reassignment Suspected or Allocation Incomplete.
  - Status__c: Open, In Progress, Resolved or Closed - No Action.
  - Held_Row_Count__c, Held_Amount__c, Last_Seen_Date__c, Follow_Up_Key__c, Suggested_Resolution__c,
    Resolution_Notes__c, Assigned_To__c, AI_* fields.
  - Added in 4b.2: AI_Homework__c, AI_Field_Suggestions__c, Asked_Firm_At__c.
- **Rep_Code_Assignment__c**
  - Advisor__c, Allocation_Percent__c, Effective_Start_Date__c, Effective_End_Date__c, End_Date_Source__c,
    Last_Confirmed_Trade_Date__c.
  - Rep_Code__c has Active_Allocation_Total__c (a roll-up; a validation rule keeps it at 100 or below).
- **Mapping_Profile__c**
  - Source_Firm__c, Firm__c, Single_Firm_Feed__c.
  - Feed_Type__c: Trade Activity or Advisor Code Roster.
  - Column_Map__c (JSON), Header_Fingerprint__c, Date_Format__c, Decimal_Separator__c, Direction_Convention__c,
    AUM_Indicator_Values__c, AI_Rationale__c, Proposed_From_Batch__c.
  - Status__c: Draft, Active or Retired.
- **AI_Request_Log__c**
  - Purpose__c: Row Suggestions, Mapping Proposal or Firm Follow-up.
  - Status__c: Success, Invalid Response or Failed.
  - Provider__c, Model_Name__c, Prompt__c, Response__c, Error_Message__c, Item_Count__c, Duration_Ms__c,
    Import_Batch__c.
  - Added in 4b.2: Input_Tokens__c, Output_Tokens__c, Cached_Input_Tokens__c.
- **Matching_Rule__c**
  - Firm__c, Rule__c (plain-language convention sent to Claude), Status__c (Proposed, Active or Retired),
    Approved_By__c, Approved_At__c. Two-person approval is optional.
- **Trade_AI_Setting__mdt**
  - Enabled__c, Provider__c ('Models API' by default; only the exact value 'Anthropic API' switches),
    Model_Name__c, Anthropic_Model__c, Max_Items_Per_Request__c (10), Require_Two_Person_Rule_Approval__c.
  - Redeploying resets Provider back to Models API.

**Permission sets**
- **Trade Import Admin**: full access, plus edit on Account.Operations_Contact__c.
- **Trade Import Integration**: least privilege for the push job user and its background jobs.
- **Trade Import Reviewer**: works the queue. Background work runs as the reviewer, so it has the same data access
  as Integration plus the roster writes. It can also read Contact.Email and Operations Contact. The test
  `theReviewerPermissionSetIsEnough` runs every reviewer action as a Standard User holding only this permission set.
- **Trade Import Anthropic API**: Standard tier only. Principal access `Anthropic_API-Anthropic` and read on
  UserExternalCredential.

Claude calls also need the org's generative AI permission (Enterprise tier) or this last permission set
(Standard tier).

**Credentials (Standard tier):** External Credential `Anthropic_API` uses a Custom protocol. Its AuthHeader is
`x-api-key = {!$Credential.Anthropic_API.ApiKey}`, with principal `Anthropic`. Named Credential `Anthropic_API`
points to https://api.anthropic.com. No Apex depends on either at compile time.

## 7. Matching rules (TradeMatcher)

- **Firm:**
  - an exact alias key resolves the firm;
  - a fuzzy match is accepted automatically at a score of 0.9 or more with a margin of 0.1 over the next candidate,
    otherwise up to 3 candidates are kept;
  - a single-firm feed fills in a missing firm.
- **Code and advisor:** the code is looked up within its firm, then the assignments effective on the trade date.
  - A team code splits the trade by allocation percentage, unless the named advisor is on the team (full credit).
  - Dormancy is 180 days.
- **Fund:** alias, then fuzzy.
- **Flags:**
  - Firm: FIRM_MISSING, FIRM_UNRESOLVED, FIRM_AMBIGUOUS, FIRM_FUZZY.
  - Fund: FUND_UNRESOLVED, FUND_AMBIGUOUS, FUND_FUZZY.
  - Code: UNKNOWN_CODE, CODE_ENDED, DATE_BEFORE_CODE_START, DORMANT_CODE_NO_NAME, DORMANT_CODE_REACTIVATED,
    REASSIGNMENT_SUSPECTED, TEAM_CHANGE_SUSPECTED, ALLOCATION_INCOMPLETE.
  - Advisor and split: TEAM_SPLIT, SINGLE_ADVISOR_CREDIT, NEW_ADVISOR, ADVISOR_AMBIGUOUS.
  - Roster: ROSTER_NEW_CODE, ROSTER_NEW_HOLDER, ROSTER_CONFIRMS.
  - Decisions: FOLLOW_UP_CLOSED, *_FROM_CLAUDE, *_FROM_REVIEWER.
- **Held rows:** code problems hold the row behind one Code Follow-Up per firm, code and reason. Resolving the
  follow-up re-matches its rows.
- **Roster rows:** approving one (RosterApprovalService) creates the advisor and code, ends the old holder's
  assignment on the day before, assigns the code 100% from the roster date, and closes the follow-up, re-matching
  its held trades. `preview()` lists those steps before the reviewer clicks. Roster rows are authoritative for Claude.

## 8. Claude integration

**Code layout**
- `ClaudeService.call(purpose, prompt, batchId, itemCount)` returns a Result with an unsaved log. Callers insert the
  log after the callout.
- `ClaudeClient.complete(model, prompt)` returns a Completion: text, input tokens, output tokens, cached input
  tokens.
  - ModelsApiClient uses `aiplatform.ModelsAPI.createGenerations` and reads usage by JSON round-trip of
    `response.Code200`.
  - AnthropicApiClient splits the prompt at `ClaudeService.CACHE_BREAK`. The part before it becomes a cached system
    block (`cache_control: ephemeral`). Max tokens 8000, timeout 60 s.
- Input tokens count cache reads and cache writes; cached tokens count cache reads only. `FakeClaudeClient` is the
  test double.

**Safety**
- Claude sees short keys (R1, F1, P1, A1), never Salesforce Ids.
- Answers are validated strictly: unknown items or fields, duplicate fields and values outside the choices are
  rejected. The rule "accept needs the firm and fund the row asks for" is enforced.
- Text is length-capped (headline 100, reason 500, homework 1000).
- `readable()` replaces keys with record names before storing; codes that look like keys are protected.
- The validation is mirrored in Python (`tools/verify/port.py`). Shared vectors generate
  `ClaudeValidationVectorTest`.

**Suggestion answer format 2**
`{"suggestions":[{"item","headline","fields":[{field,value,confidence,reason}],"action":"accept|reject|hold","homework","confidence","explanation"}]}`

**Mapping proposals:** an unknown header fingerprint sends the batch to Mapping Review. Claude proposes a Draft
profile, and Activate mapping in the app processes the waiting file.

**Firm follow-up email**
- `ReviewController.draftFirmEmail` gathers the firm's on-hold rows and open code reviews and writes one question
  each, with no amounts. Claude writes JSON `{subject, body}`, logged as Purpose 'Firm Follow-up'.
- If Claude's answer is unusable, it's logged Invalid and a standard numbered list is used instead. The body is
  HTML-escaped.
- The LWC opens `standard__quickAction` `Global.SendEmail` with `encodeDefaultFieldValues({ToAddress, Subject,
  HtmlBody, RelatedToId})` and `state.recordId` set to the firm Account. A person sends it, and it's logged on the
  Account.
- `markAsked` stamps Asked_Firm_At__c on each item. A reminder label appears after 3 days.

**Model accuracy so far:** codes 3102, 5521 and 8800 come out correct; Hannah Pierce was fixed by the
roster-is-authoritative rule.

## 9. Trade Review app (LWC `tradeReview`, tab `Trade_Review`)

**Tabs, in order (4b.2a)**

| Tab | What's in it |
|---|---|
| **Dealer Code Review** | Codes to fix, with held trades; then roster and code decision rows (`isCodeIssue`: a roster row or any code flag) |
| **Needs Decision** | Firm, fund and other data rows, grouped by file |
| **On Hold** | Rows put on hold, with their homework |
| **Email Firms** | One line per firm with questions waiting; the detail lists each question, the contact, Email the firm and Mark as asked |
| **New File Format** | Files waiting for a mapping; Activate mapping |
| **Recent Files** | The last 10 files and their outcomes |

**Shared table:** every queue uses `reviewQueueTable` with three columns:
- Item: headline, origin, assignment or asked date.
- Issue type: plus "+N more", and badges for Claude's confidence and recommended action.
- Amount or count.

It supports group header lines.

**Row detail**
- The headline (Claude's, or one built from the flags), then the origin line.
- File values; "Why it needs review" (notes, each once); Claude's Field / Suggestion / Confidence / Reason table,
  recommendation and homework.
- For roster rows, "Approving will" (Approve is off when `canApprove` is false; a missing firm can still be chosen).
- Decision controls: Accept or Approve roster entry, Reject, Put on hold (on open rows) or Release (on held rows),
  Assign to me or Unassign.

**Elsewhere in the app**
- Upload file: CSV up to 1 MB.
- All / Mine / Unassigned scope filter.
- Polls every 5 s, up to 36 times, while background work runs.

**Other LWCs**
- `aiSuggestionTable`: record pages for SR and CF.
- `reviewQueueTable`: the shared table.

**ReviewController @AuraEnabled methods (parameter names matter)**
- `getQueue(scope)`
- `decideRow(rowId, decision, firmId, fundId, advisorId, rememberChoice)`
- `setAssignment(recordId, assignToMe)`
- `activateMapping(profileId)`
- `uploadFile(sourceFirm, fileName, base64Content)`
- `holdRow(rowId, homework)`
- `releaseHold(rowId)`
- `draftFirmEmail(firmId)`
- `markAsked(itemIds)`
- `getIssueRows(rowId)` (4b.3: up to 50 rows sharing the row's issue)

decideRow, holdRow and releaseHold return how many rows changed (a whole issue group, up to 200 per call).

**Grouping (4b.3):** RowItem carries groupCount, groupAmount and groupFileCount. One row stands for each issue group (light query, then an aggregate for totals).

**Queue shape:** rows, holdRows, followUps, firmFollowUps (with questions), mappings, recentFiles, options,
claudeEnabled, provider, inFlight, userId, rowsTruncated. Limits: 200 rows, 100 follow-ups, 10 recent files.

## 10. Demo data and scripts

**Seed records**
- Firms: Barder & Company (Oakville and Hamilton branches); Northgate Wealth Partners Inc. (Toronto); Lumière
  Valeurs Mobilières Ltée (Montréal); Kestrel Capital Inc. (Calgary); Kestrel Capital Ltd. (Vancouver).
- Advisors: Julia Morales, Marcus Bell, Tom Reilly, Aisha Khan, Daniel Okafor, Sam Whitford, Élise Gagnon,
  Marc-André Roy, Ryan Chen, Megan Chen.
- Codes: 3102, 457, 2210, 5521, 7700, 8800, 1001 (one at each Kestrel firm).
- Funds: Wealth World Fund Series A and F, Wealth World ETF, Canadian Dividend Fund A, Global Bond Fund F.
- Seed trap: the alias "Wealth World Fund" exists for both Series A and Series F, which produces FUND_AMBIGUOUS.

**Sample files** (`datalake/samples`)

| File | What it plants |
|---|---|
| `inbox/BARDER/barder_trades_2026-10-05.csv` | Row 6: fund unknown. Row 11: dated before code 457 started. Row 12: fund ambiguous |
| `inbox/BARDER/barder_trades_2026-10-05_resent.csv` | A duplicate of the Barder file under another name |
| `inbox/NORTHGATE/northgate_trades_2026-10-05.csv` | Row 12: firm unresolved ("Northgate Securities Ltd") |
| `inbox/NORTHGATE/northgate_trades_2026-10-06.csv` | Damaged in transit (unclosed quote), so the batch Fails |
| `inbox/LUMIERE/lumiere_transactions_2026-10-05.csv` | Row 6: team change on 7700 |
| `inbox/KESTREL/kestrel_export_2026-10-05.csv` | Unknown format, so Claude proposes a mapping. After activation: 2 firm-ambiguous rows and 1 firm-missing row |
| `roster/BARDER/barder_advisor_codes_2026-10-05.csv` | Priya Nair as new holder of 2210; Hannah Pierce, a new advisor, on new code 3390 |

Code reviews this produces: 2210 reassignment, 3390 unknown, 8800 allocation under 100%, 3102 ended, 5521
dormant, 7700 someone not on the team. Not planted: ADVISOR_AMBIGUOUS.

**Scripts**
- `scripts\reset-demo-full.ps1` (`-NoPush`, `-TargetOrg`):
  1. `reset-imports.apex`;
  2. `reset-reference-data.apex` (generated from the seed);
  3. `seed-mapping-profiles.apex`;
  4. push the roster, wait 30 s, push the trades.

  Wait about 2 minutes before opening the app.
- `scripts\reset-demo.ps1` copies the samples to the inbox.
- Other Apex scripts: `request-suggestions.apex`, `demo-resolve-2210.apex`, `test-models.apex`.

**Push job**
```powershell
pushjob\.venv\Scripts\python.exe pushjob\push_job.py --lake datalake --once --auth sfcli --target-org tradeDemo
```
`--watch` and `--interval` poll continuously. `--auth jwt` needs `SF_CLIENT_ID`, `SF_USERNAME` and
`SF_PRIVATE_KEY_FILE`; see `pushjob/JWT_SETUP.md` (External Client App, Spring '26).

## 11. Build and verification pipeline

The source of truth for metadata is the generator, not hand-edited XML. The generators and checks are copied into
`tools/` (section 13). They were written for the assistant's workspace, so their paths start with `/home/claude/`;
change the root variables before running them elsewhere.

**Metadata and test generators**
- `tools/gen/gen_metadata.py` writes every object, field, layout, list view, tab, permission set, the custom
  metadata type, and the credentials. To add a field, call `field(obj, api, label, kind, desc, help, ...)` and add
  it to the layouts; permission-set field access follows object access.
- `tools/gen/gen_seed.py` writes the `data/*.json` seed files.
- `tools/verify/gen_tests.py` writes the vector tests (TradeRowNormalizerVectorTest, CsvParserTest,
  NameNormalizerTest, NameMatcherTest).
- `tools/verify/gen_tests3b.py` writes ClaudeValidationVectorTest.
- `tools/verify/gen_samples3.py` writes the sample files.
- `tools/verify/gen_reset_full.py` writes the reset Apex.

**Checks to run before anything goes to the org**
1. prettier-plugin-apex parses every class, trigger and anonymous script.
2. PMD 7 security, performance and error-prone rules: zero findings.
3. `apex_lint.py` catches:
   - a byte order mark;
   - an Assert message that can be null;
   - String.isBlank misuse;
   - an invalid identifier;
   - a reserved word used as a variable name (added after `system` broke a dry run);
   - SOQL with both FOR UPDATE and ORDER BY.
4. `xref.py` checks that every field and relationship used in Apex exists in the metadata.
5. `lwc_xref.py` checks every LWC Apex import exists as @AuraEnabled, every call passes exactly the parameter names
   (shorthand properties included), and every `@salesforce/schema` import exists.
6. Jest (sfdx-lwc-jest) with ESLint and Prettier (double quotes, no trailing commas): 50 tests (42 tradeReview, 3 reviewQueueTable, 5 aiSuggestionTable).
7. Python ports and vectors: `check_vectors.py`, `check_claude_vectors.py`.
8. Negative controls: break something on purpose and confirm the check fails.

**Dry-run command** (22 test classes; expected test count in section 5):
```powershell
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests FileIntakeServiceTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewControllerTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```
To deploy for real, run the same command without `--dry-run --verbose`.

## 12. Platform lessons learned (don't repeat these)

**Apex**
- `system` (and other reserved words) can't name a variable. The local parser allows it; the org doesn't.
- `'\n'` in an Apex string literal is a real line break. A JSON string in a test needs `'\\n'`.
- AuraHandledException hides its message in tests unless `setMessage()` is also called. ReviewController's
  `fail()` helper does both.
- Fund_Alias__c's lookup is `Fund__c`, not `Product__c`.

**LWC**
- LWC drops whitespace between an element and an expression (`<span>Firm:</span> {value}`). Use separate spans with
  a CSS margin.
- Jest: `lightning-button[label=…]` attribute selectors don't work; select by class.
- Jest: the stock `lightning/navigation` stub records nothing; the tests mock it inline.

**Process**
- A full demo run needs about 2 minutes of background jobs before you query the results.
- Ambiguity needs one exact alias shared by two records; fuzzy matching alone never produces FUND_AMBIGUOUS.
- Two suggestion jobs at once can race. The guard for this is planned in 4e.
- SOQL can't combine ORDER BY with FOR UPDATE (the local parser allows it); `apex_lint.py` now flags it.
- `group` is reserved too (caught by the lint rule).
- Re-matching only picks up Pending rows, so remembering a spelling doesn't clear other open rows. Group decisions (4b.3) cover that.

## 13. File map (`C:\dev\trade-import-demo`)

- **`force-app/main/default/`**
  - `classes/` (54 Apex files), `triggers/`, `lwc/`, `objects/`, `layouts/`, `permissionsets/`, `tabs/`,
    `customMetadata/`, `externalCredentials/`, `namedCredentials/`.
- **`data/`**: seed JSON and `seed-plan.json`.
- **`datalake/`**: `samples/` (source files) and `inbox/` (what the push job reads).
- **`pushjob/`**: the push job, its tests and JWT setup.
- **`scripts/`**: the reset scripts and Apex scripts.
- **`tools/verify/`**: the checks and Python ports.
- **`tools/gen/`**: the metadata, seed and build-log generators.
- **`docs/Trade_Import_Build_Log.docx`**: the build log, generated by `tools/gen/build_doc.js` with field
  definitions from `tools/gen/dump_fields.py`.
- **Run guides**: `PHASE1.md` to `PHASE4B2.md`.

**Apex classes**
- Services: AiSettings, AnthropicApiClient, ClaudeClient, ClaudeService, ClaudeSuggestionJob,
  ClaudeSuggestionService, CodeFollowUpService, CsvParser, FileIntakeService, ImportBatchProcessor,
  MappingActivationService, MappingProposalJob, MappingProposalService, MappingService, MatchingRuleService,
  NameMatcher, NameNormalizer, ProductDeleteGuard, ReviewController, ReviewDecisionService, RosterApprovalService,
  TradeIngestResource, TradeMatcher, TradeRowNormalizer.
- Test support: FakeClaudeClient, TestDataFactory, TradeTestWorld.
- Tests: one `*Test` class per service, plus DemoScenarioTest and the vector tests.

## 14. Open decisions and ideas

- **Mixed rows (decided 2026-10-25):** a row with both a code issue and another issue goes to Dealer Code Review only,
  with its other issues listed in the detail. Reason: insiders do most of this work, so keep it as simple as possible.
- **Shared issues (decided 2026-10-25):** one line per issue; one decision reaches every open row with that issue
  from the same dealer, in any file.
- **Cost idea:** Claude is still asked about every row in a group; asking once per issue would cut cost.
- **4c, cloud pull:** S3, Azure Blob and Google Cloud Storage, through FileIntakeService. Credentials go in Named
  Credentials.
- **4d, Setup Assistant:** a guided wizard covering all three intake paths. Reviewers may be a single champion or a
  team, so assignment stays optional.
- **4e:**
  - Confirm holder for dormant codes.
  - Duplicate-job guard.
  - Loading approved rows into Trade, Trade Allocation and AUM records.
  - Notifications instead of polling.
  - Possibly parsing email replies.
