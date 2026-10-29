# Phase 4b.2: review feedback

**Update 4b.5 (review feedback):** see section 20 of the build log. Code reviews are settled in Trade Review: credit
one advisor who holds the code (**Credit all N rows**), **Code fixed: re-match**, or **Decide rows one by one**. The
summary line and Held rows table say which rows are trades and which are AUM balances. When Claude leaves a field
open, the Suggestion cell lists the choices it weighed (or *Ask the firm*), and the lines under Claude's table are
headed **Why** and **Question for the firm**. No new fields. Validate with **163 tests**.

**Update 4b.4 (audit fixes, part 1):** see section 19 of the build log. Visible changes: a row whose advisor name
fits some but not all members of a team code (for example "Chen") now waits in Dealer Code Review with those members
as the choices, instead of being split across the whole team; each firm in a multi-firm dealer file gets its own code
review. New field Advisor Override. Validate with **159 tests**, then run the full demo reset (code reviews are now
keyed by firm, so old open ones are replaced).

**Update 4b.3 (shared issues):** rows with the same problem are one line. The same unknown fund spelling, unknown
firm spelling, or missing or ambiguous firm (per rep code) from the same dealer, across every file still waiting, shows
as one line with how many rows it affects, their total and how many files: *37 rows · $412,000.00*. Opening it says
"This issue affects 37 rows … Your decision applies to all of them" and lists the rows. The buttons say **Accept all
37**, **Reject all 37**, **Put all 37 on hold**. Holding a group asks the firm one question ("37 rows across 3 files").
Code issues and roster rows are still decided one by one in Dealer Code Review. Decisions apply up to 200 rows at a
time; a bigger group stays in the queue with the rest, ready for the next click. **Run the full demo reset after
deploying**: existing rows get their issue key only when they are matched again.

**Update 4b.2a (tab layout):** the tabs are now **Dealer Code Review, Needs Decision, On Hold, Email Firms, New File
Format, Recent Files**, and every tab uses the same table: the item, its issue type (with Claude's confidence and
recommendation) and the amount or count.

- **Dealer Code Review** holds everything about a rep code: the codes to fix (with their held trades) and every
  roster row or trade row whose issue is the code (new holder, new code, unknown or ended code, dated before the code
  started, dormant code, reassignment, team change, shares under 100%). A row with a code issue and another issue
  goes here; its other issues are listed in its detail.
- **Needs Decision** holds the rest (firm, fund and other data questions), grouped by file.
- **Email Firms** is its own tab: one line per firm with questions waiting, its Operations Contact and how many were
  asked. Selecting a firm lists each question (where it came from, and when it was asked) with **Email the firm**.

What changes in Trade Review:

- **Titles say what is wrong**, by name: *Priya Nair · Rep code mismatch on 2210*. The file and row number move to
  the line underneath. Claude's own headline replaces the rule-based one once it answers.
- **Why it needs review** lists each specific note once.
- **Put on hold**: a fourth decision for rows only the dealer can settle. Say what needs to be found out (Claude
  pre-fills it when it recommends Hold). The row moves to the new **On Hold** tab, where you can **Accept**,
  **Reject** or **Release** it back to Needs Decision.
- **Roster rows show what approving will do**: create the advisor, create the code, end the old holder's assignment,
  assign the code, close the code review and re-match its trades. If a row cannot be approved, it says why and
  Approve is switched off.
- **Claude's answer is a table**: Field, Suggestion, Confidence, Reason, with its recommended action. The same
  table is available on the record pages (component **AI Suggestion Table**).
- **Waiting for the firm**: one email per firm covering its on-hold rows and code reviews, drafted by Claude,
  opened in Salesforce's Send Email window for you to edit and send. Afterwards, mark the questions as asked; items
  then show *Asked Oct 20*, and a reminder label after 3 days. Amounts are never included.
- Every AI Request Log records **input, output and cached tokens**. On the Standard tier the instructions are
  cached, so repeat requests cost less.
- The missing space in *Firm:Northgate…* is fixed.

## 1. Validate (22 test classes, expect 163 tests)

```powershell
cd C:\dev\trade-import-demo
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests FileIntakeServiceTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewControllerTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only on `Status: Succeeded`. If anything fails, send the full output. The new tests most likely to need a
tweak are `ReviewControllerTest.rosterRowsSayWhatApprovingWillDo` (it checks the exact wording of each step) and
`theReviewerPermissionSetIsEnough` (it now also holds, emails, marks as asked and releases as a reviewer-only user).

## 2. Deploy

The same command without `--dry-run --verbose`.

## 3. One-time setup after the deploy

1. **Operations Contact on the Account layout.** Setup → Object Manager → Account → Page Layouts → your layout →
   drag **Operations Contact** onto it → Save. (Standard object layouts are not part of this package.)
2. **Set an Operations Contact on the demo firms.** On *Barder & Company* and *Northgate Wealth Partners*, create
   or pick a Contact whose **Email is your own address**, and set it as Operations Contact. The demo firms are
   fictional, so the email should only ever reach you.
3. **AI Suggestion Table on the record pages.** Open any Import Staging Row → gear → **Edit Page** → drag **AI
   Suggestion Table** (Custom) into the right column → **Save** → **Activate** → *Assign as Org Default* → Save.
   Repeat on a Code Follow-Up record.

## 4. Reset the demo and try it

```powershell
.\scripts\reset-demo-full.ps1
```

Give it two minutes, then open Trade Review.

| Try | You should see |
|---|---|
| Needs Decision titles | *Priya Nair · Rep code mismatch on 2210*, *Hannah Pierce · New advisor, new code 3390*, *Unknown fund · "…"*, then Claude's own headlines once it answers |
| Priya Nair's roster row | *Approving will* lists: end Marcus Lee's assignment, assign 2210 to Priya Nair, close the 2210 code review and re-match its held trades |
| Any row Claude has answered | The Field / Suggestion / Confidence / Reason table and *Claude recommends: …* |
| Barder row 11 (dated before the code started) | Put on hold; the dialog is pre-filled if Claude recommended Hold. The row moves to On Hold |
| Email Firms tab | *Barder & Company* with its questions listed. Click **Email the firm**: the Send Email window opens addressed to your contact. Send it, then **Mark as asked** |
| On Hold tab | The held row shows *Asked* with the date; **Release** sends it back to Needs Decision |
| The firm Account | The email in its activity history |
| AI Request Logs | Input, Output and Cached Input Tokens on every new log; a *Firm Follow-up* log for the email |

If a firm shows *No Operations Contact with an email on the firm*, step 3.2 has not been done for it.

## 5. Optional: run the LWC tests on your computer

```powershell
npm install
npm run test:unit
python tools\verify\lwc_xref.py force-app\main\default
```

50 Jest tests should pass across the three components. `lwc_xref.py` checks every Apex call from the app passes exactly the parameter names
the Apex method expects, and every field the components import exists in the package.
