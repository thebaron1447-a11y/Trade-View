# Trade View: architecture

How Trade View is built: the pipeline, the data model, the matching rules, how Claude is used safely, the review app,
the demo data and how the code is checked. For an overview and setup steps see [README.md](README.md).

## 1. How it works

Dealers (other investment firms) send CSV files of trades, AUM and advisor rep-code rosters. Files arrive through:
- a **push job** (Python, REST endpoint `/services/apexrest/trade-import/v1/files`);
- an **upload** in the app;
- later, a **cloud storage pull** (phase 4c).

Every route goes through **FileIntakeService**, which runs a SHA-256 duplicate check and a 1 MB limit, then saves
the file to an **Import Batch** with a ContentVersion.

A **Mapping Profile**, recognised by a header fingerprint, maps the columns. Rows are normalised into **Import
Staging Rows**, then matched rule-first by **TradeMatcher**: firm, rep code, the advisor(s) on the trade date, and
the fund. Each row ends as **Matched**, **Needs Review**, **Held** (behind a **Code Follow-Up**) or **Invalid**.

**Loading.** When a reviewer clicks **Load file** (Recent Files), **TradeLoader** books the file's matched Trade
and AUM rows in the background, 200 rows per queued job, each all or nothing. A Trade row becomes a **Trade** with
one **Trade Allocation** per credited advisor; an AUM row becomes an **AUM Balance** with **AUM Allocations**.
Credit follows matching: a Credited Advisor gets 100%, a team row splits by the shares active on the row's date
(which must total 100%). **TradeAllocator** splits to the cent: each share is rounded towards zero and leftover cents
go to the largest shares, so allocations always add up to the trade's signed amount (redemptions negative) or the
balance. If a team's shares changed after matching so they no longer total 100%, or a trade lost its fund, the row
is not booked: it goes back to Pending with a note and matching holds it or sends it to review, as for a new row.
A trade's Load Key is its row Id (unique) and an AUM Balance's key is code, fund (or ALL) and as-of date (unique), so
nothing is booked twice and a re-sent balance replaces the earlier one with a fresh split. Booked rows get Loaded At
and a link to what they became, and a trigger lock stops their match changing afterwards (only a data fix can). When
the last chunk is done the file is **Completed** if no row is waiting, else back to **Pending Review**, and Load file
appears again once more rows are matched. Matching never touches a file while it is Loading; rows a decision sends
back meanwhile are matched when the load finishes. A failed chunk saves nothing, puts the file back to Pending
Review and shows the error on it.

**Notifications (4e.2).** **TradeViewNotifier** publishes a **Trade View Update** platform event (published after
commit; it carries only the kind of work and the batch Id) at the end of reading a file, matching, a Claude job, a
mapping proposal and each load step. Trade Review subscribes with `lightning/empApi` and refreshes once per burst of
updates (750 ms debounce). While it is listening it checks only every 30 seconds as a safety net; if it cannot listen,
it falls back to checking every 5 seconds for up to 3 minutes. The person waiting on a file (Import Batch Notify User:
set by an upload in the app or by Load file, never by the push job) gets a bell notification (custom notification type
Trade View, opening the Trade Review tab) when it is read into Mapping Review or Failed, matched, booked, part loaded
or stopped; Notify User is then cleared, so each wait is told once. Publishing and sending never stop the work.

**Holder confirmation (4e.2).** On a Code Dormant review, **Confirm holder** records on each assignment active today
that the firm confirmed the holder still uses the code (Holder Confirmed On and By, with field history). The
dormancy check counts that date like a confirmed trade, so the review is resolved and its held rows match again and
are credited as usual. It is refused while a roster change for the code is waiting, and when nobody holds the code
today.

**Claude** then suggests answers for the rows rules can't settle. It sees short keys only, and its answers are
validated strictly. It also proposes mapping profiles for unknown file formats and drafts follow-up emails to firms.

**Who saves what.** Everything a person does (decide, hold, assign, upload, email, activate a mapping) runs in user
mode, so the permission sets decide what each role can do. Background steps save through **SystemWriter**, the one
class that writes in system mode: matching results, Claude's answers and logs, row and batch counts, decision and hold
stamps (set by the row trigger), learned aliases, and the advisors, codes and assignments a roster approval creates
or ends. Callers check what they save first. The system-owned fields are read-only for reviewers (who edit only
what a person decides: decision, overrides, remember, hold and reason, assignment, asked date, a code review's status
and notes, plus mappings, matching rules and the rep code roster) and for the integration user, which edits nothing
directly. **SystemFieldGuard**, in the before-update triggers of staging rows and code reviews, refuses changes to
system-owned fields made any other way (code or automation in system mode) unless the writer is saving or the user
holds the Trade Import Data Fix custom permission (Trade Import Admin) or Modify All Data. Field history tracks
decisions, overrides, match results, amounts, holds and assignment on rows; status, assignment and code on code
reviews; advisor, share and dates on rep code assignments; and status on batches, mapping profiles and matching
rules. SecurityModelTest checks the reviewer permission set and the guard agree (audit F-01, F-28). Everything a
load books (trades, AUM balances, allocations, load stamps) is saved by the writer and read-only for reviewers.

A person decides everything in the **Trade Review** app (an LWC on its own tab). Two tiers:
- **Enterprise** (the default): Models API and the Trust Layer.
- **Standard**: smaller firms use the Anthropic API with their own key, which also enables prompt caching.

Enterprises will almost never use the direct route, because of compliance mandates.

**Stranded work.** Each background step queues the next only when its transaction still has a queueable slot, and
Developer Edition limits chain depth, so a step can end without starting the next. **StrandedWorkSweeper**, scheduled
at :00, :15, :30 and :45 (`scripts/apex/schedule-sweeper.apex`), restarts files left Received, rows left Pending in
staged files, rows and code reviews never sent to Claude (when Claude is on), and loads left part way (a file still
Loading). It takes only work untouched for 10
minutes and skips a kind of work while a job of that kind is queued or running, so it never races a job about to
finish. Failures are never retried: a failed item is marked Failed, so nothing loops (audit F-08).

## 2. Data model

Custom objects: Import_Batch__c (IB), Import_Staging_Row__c (SR), Mapping_Profile__c (MP), Code_Follow_Up__c (CF),
Rep_Code__c, Rep_Code_Assignment__c, Firm_Alias__c, Fund_Alias__c, AI_Request_Log__c (AL), Matching_Rule__c (MR),
Trade__c, Trade_Allocation__c, AUM_Balance__c, AUM_Allocation__c. Custom metadata: Trade_AI_Setting__mdt (record `Default`).

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
  - Row, matched, review, held and error counts; Loaded_Row_Count__c (set by each load); Error_Message__c.
  - Pending Review: matched, rows may wait on a person. Loading: Load file is booking matched rows. Completed: every
    row is loaded, rejected or invalid.
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
- **Import_Staging_Row__c, loading (4e)**
  - Loaded_At__c, Loaded_Trade__c (Lookup Trade), Loaded_AUM_Balance__c (Lookup AUM Balance). A loaded row's match
    is locked.
- **Trade__c, Trade_Allocation__c**
  - Trade: Rep_Code__c, Fund__c, Trade_Date__c, Transaction_Type__c, Amount__c (positive), Signed_Amount__c
    (formula), Source_Row__c, Load_Key__c (the row Id, unique).
  - Trade Allocation (master-detail to Trade): Advisor__c, Allocation_Percent__c, Allocated_Amount__c (signed).
- **AUM_Balance__c, AUM_Allocation__c (4e)**
  - AUM Balance: Rep_Code__c, Fund__c (blank for a total per code), As_Of_Date__c, Balance__c (not negative),
    Balance_Key__c (code|fund or ALL|date, unique), Source_Row__c.
  - AUM Allocation (master-detail to AUM Balance): Advisor__c, Allocation_Percent__c, Allocated_Balance__c.
- **Rep_Code_Assignment__c**
  - Advisor__c, Allocation_Percent__c, Effective_Start_Date__c, Effective_End_Date__c, End_Date_Source__c,
    Last_Confirmed_Trade_Date__c, Holder_Confirmed_On__c and Holder_Confirmed_By__c (4e.2, set by Confirm holder).
- **Import_Batch__c.Notify_User__c** (4e.2): who gets the bell when the file's background work finishes.
- **Trade_View_Update__e** (4e.2): platform event, Kind__c and Record_Id__c. Reviewers read it; Apex publishes it.
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

## 3. Matching rules

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
  follow-up re-matches its rows. From the app, `creditCodeReview` settles an Allocation Incomplete, Reassignment
  Suspected or Code Dormant review by setting Advisor Override on every held row (only someone holding the code on
  each row's date) and resolving it; `closeCodeReview` resolves it after the code is fixed, or closes it so the rows
  go to Needs Decision. Each adds a dated line to Resolution Notes.
- **Roster change first, row by row:** when a roster row for the same firm and code waits for a decision and the
  review's reason is one a roster change settles, held rows it covers wait for it. Rules decide coverage, not Claude:
  the roster change must be approvable as it stands (same rule as the Approve button), and a held row must be dated on
  or after the roster date and name the roster advisor (NameMatcher) or no one. Covered rows cannot be credited,
  re-matched or sent to review; the others can, and the review stays open for the covered ones. Re-match waits while
  any row is covered, because the roster change is the fix. Approving the roster change resolves the review; rejecting
  it releases the lock. The app links both items and marks each waiting row.
- **Roster rows:** approving one (RosterApprovalService) creates the advisor and code, ends the old holder's
  assignment on the day before, assigns the code 100% from the roster date, and closes the follow-up, re-matching
  its held trades. `preview()` lists those steps before the reviewer clicks. Roster rows are authoritative for Claude.

## 4. Claude integration

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

## 5. Trade Review app

**Tabs, in order (4b.2a)**

| Tab | What's in it |
|---|---|
| **Dealer Code Review** | Codes to fix, with held trades; then roster and code decision rows (`isCodeIssue`: a roster row or any code flag) |
| **Needs Decision** | Firm, fund and other data rows, grouped by file |
| **On Hold** | Rows put on hold, with their homework |
| **Email Firms** | One line per firm with questions waiting; the detail lists each question, the contact, Email the firm and Mark as asked |
| **New File Format** | Files waiting for a mapping; Activate mapping |
| **Recent Files** | The last 10 files and their outcomes; **Load file** on a file with matched rows ready to book |

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

## 6. Demo data and scripts

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

## 7. Build and verification

The source of truth for metadata is the generator, not hand-edited XML. The generators and checks are in `tools/`.
They currently use absolute paths (`ROOT`, `OUT`, `BUILD`, `APEX` near the top of each script); point them at your
copy of the repository before running them.

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
   (shorthand properties included), and every `@salesforce/schema` import exists. A call is matched by its whole
   name, so `uploadFile(` is not read as `loadFile(`.
6. Jest (sfdx-lwc-jest) with ESLint and Prettier (double quotes, no trailing commas): 62 tests (53 tradeReview, 3 reviewQueueTable, 6 aiSuggestionTable).
7. Python ports and vectors: `check_vectors.py`, `check_claude_vectors.py`.
8. Negative controls: break something on purpose and confirm the check fails.

**Dry-run command** (29 test classes, 206 tests; run `scripts/apex/unschedule-sweeper.apex` first):
```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests FileIntakeServiceTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewControllerTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests SystemWriterTest --tests SecurityModelTest --tests StrandedWorkSweeperTest --tests TradeAllocatorTest --tests TradeLoaderTest --tests TradeViewNotifierTest --tests HolderConfirmationTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```
To deploy for real, run the same command without `--dry-run --verbose`.

## 8. Platform lessons learned

- **Scheduled jobs lock the code they reach.** A deploy fails with "This schedulable class has jobs pending or in
  progress" for every class a scheduled job depends on (for the sweeper, nearly all of them). Run
  `scripts/apex/unschedule-sweeper.apex` before deploying and `schedule-sweeper.apex` after;
  `scripts/deploy.ps1` (with `-DryRun` to validate) does both around the deploy, with every test class in the folder. The Deployment
  Settings bypass exists, but it lets a running job pick up half-deployed code, so it stays off.

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
