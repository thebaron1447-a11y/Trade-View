// Builds the running build log & architecture document. Re-run after each phase.
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, AlignmentType, LevelFormat, Footer, PageNumber,
} = require("docx");

const spec = JSON.parse(fs.readFileSync(__dirname + "/spec.json", "utf8"));
// Field definitions read from the built metadata by dump_fields.py, so the log cannot drift from what is deployed.
const live = JSON.parse(fs.readFileSync(__dirname + "/fields_live.json", "utf8"));
const FONT = "Calibri";
const MONO = "Consolas";
const ACCENT = "1F4E79";
const CONTENT_W = 9360; // US Letter, 1" margins

// ------------------------------------------------------------------ helpers
const runs = (text, opts = {}) => {
  // **bold** segments inside text
  return text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((t) =>
    t.startsWith("**") ? new TextRun({ text: t.slice(2, -2), bold: true, ...opts }) : new TextRun({ text: t, ...opts }));
};
const P = (text, opts = {}) => new Paragraph({ children: runs(text), spacing: { after: 120 }, ...opts });
const H1 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun(t)], pageBreakBefore: false });
const H2 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(t)] });
const H3 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_3, children: [new TextRun(t)] });
const B = (t, level = 0) => new Paragraph({ numbering: { reference: "bullets", level }, children: runs(t), spacing: { after: 60 } });
const N = (t, ref = "num1") => new Paragraph({ numbering: { reference: ref, level: 0 }, children: runs(t), spacing: { after: 60 } });
const CODE = (lines) => lines.map((l, i) => new Paragraph({
  children: [new TextRun({ text: l === "" ? " " : l, font: MONO, size: 18 })],
  shading: { type: ShadingType.CLEAR, color: "auto", fill: "F2F2F2" },
  spacing: { after: i === lines.length - 1 ? 160 : 0 },
}));

const border = { style: BorderStyle.SINGLE, size: 4, color: "BFBFBF" };
const borders = { top: border, bottom: border, left: border, right: border };
function table(headers, rows, widths) {
  const total = widths.reduce((a, b) => a + b, 0);
  const cell = (text, w, head) => new TableCell({
    width: { size: w, type: WidthType.DXA },
    borders,
    shading: head ? { type: ShadingType.CLEAR, color: "auto", fill: "DCE6F1" } : undefined,
    margins: { top: 60, bottom: 60, left: 100, right: 100 },
    children: String(text).split("\n").map((t) => new Paragraph({ children: runs(t, { size: 18, bold: head || undefined }) })),
  });
  return [new Table({
    width: { size: total, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: headers.map((h, i) => cell(h, widths[i], true)) }),
      ...rows.map((r) => new TableRow({ children: r.map((c, i) => cell(c, widths[i], false)) })),
    ],
  }), new Paragraph({ children: [], spacing: { after: 120 } })];
}

// Field block in the agreed format
function fieldBlock(f) {
  const line = (k, v) => new Paragraph({
    children: [new TextRun({ text: k + ": ", bold: true, size: 20 }), new TextRun({ text: v, size: 20 })],
    spacing: { after: 0 }, indent: { left: 200 },
  });
  return [
    line("Name", f.name), line("API", f.api), line("Type", f.type), line("Description", f.desc),
    new Paragraph({
      children: [new TextRun({ text: "Help: ", bold: true, size: 20 }), new TextRun({ text: f.help, size: 20 })],
      spacing: { after: 160 }, indent: { left: 200 },
      border: { bottom: { style: BorderStyle.SINGLE, size: 2, color: "D9D9D9", space: 4 } },
    }),
  ];
}

const REF_LABEL = { Account: "Account", Contact: "Contact", Product2: "Product2", Rep_Code__c: "Rep Code", Trade__c: "Trade", Import_Batch__c: "Import Batch", Mapping_Profile__c: "Mapping Profile" };
function typeText(f) {
  switch (f.kind) {
    case "lookup":
      if (f.ref === "Product2") return "Lookup(Product2), optional at field level, clear value if deleted; required via validation rule Fund_Required";
      return `Lookup(${REF_LABEL[f.ref]})` + (f.required ? ", required, delete restricted" : ", clear value if deleted");
    case "md": return `Master-Detail(${REF_LABEL[f.ref]})`;
    case "date": return "Date" + (f.required ? " (required)" : "");
    case "text": return `Text(${f.length})` + (f.unique ? ", Unique, External ID" : f.external_id ? ", External ID (not unique)" : "");
    case "number": return `Number(${f.precision},${f.scale})`;
    case "longtext": return `Long Text Area(${f.length})`;
    case "checkbox": return "Checkbox (default unchecked)";
    case "percent": return "Percent(3,2)" + (f.required ? " (required)" : "");
    case "currency": return "Currency(16,2)" + (f.required ? " (required)" : "");
    case "formula": return `Formula (Currency, 2 decimals): ${f.formula}`;
    case "summary": return f.summary
      ? "Roll-Up Summary (COUNT of Import Staging Row, filter: Has Errors equals true)"
      : "Roll-Up Summary (SUM of Rep Code Assignment Allocation Percent, filter: Effective End Date equals blank)";
    case "picklist": return `Picklist (values: ${f.values.join(", ")})` + (f.required ? " (required)" : "");
  }
  return f.kind;
}
const OBJ_LABEL = {
  Rep_Code__c: "Rep Code", Rep_Code_Assignment__c: "Rep Code Assignment", Trade__c: "Trade",
  Trade_Allocation__c: "Trade Allocation", Firm_Alias__c: "Firm Alias", Fund_Alias__c: "Fund Alias",
  Import_Batch__c: "Import Batch", Import_Staging_Row__c: "Import Staging Row", Mapping_Profile__c: "Mapping Profile",
};

// ------------------------------------------------------------------ content
const today = "2026-10-12";
const children = [];
const add = (...xs) => xs.flat().forEach((x) => children.push(x));

add(
  new Paragraph({ children: [new TextRun({ text: "Trade Import Reconciliation", bold: true, size: 48, color: ACCENT })], spacing: { after: 80 } }),
  new Paragraph({ children: [new TextRun({ text: "Build log, solution design and data architecture", size: 28, color: "595959" })], spacing: { after: 240 } }),
  ...table(["Item", "Value"], [
    ["Author", "Greg Baronian"],
    ["Platform", "Salesforce Agentforce Developer Edition (CLI alias tradeDemo), Claude via Models API"],
    ["Project folder", "C:\\dev\\trade-import-demo (Salesforce DX project)"],
    ["Last updated", "2026-10-14"],
    ["Current status", "Phases 1 and 2 deployed and verified end to end. Phase 3A (deterministic matching and the Code Follow-Up list) built; deployed and verified end to end 2026-10-14. Phase 3B (Claude suggestions, review decisions, roster approval, mapping proposals, matching rules) deployed with fixes 3B.1 and 3B.2 (110 of 110 tests) and verified end to end 2026-10-21. Phase 4a (Standard tier: Anthropic API provider) passed the org dry run (118 tests) 2026-10-21. Phase 4b (Trade Review app) passed the org dry run (132 tests) 2026-10-22; 4b.1a (names, issue types, full demo reset, complete sample data) and 4b.2 (headlines, On Hold, per-field Claude answers, roster preview, firm follow-up email, token logging and prompt caching) passed the org dry run (145 of 145 tests) 2026-10-23; 4b.2a (one table layout, code issues in Dealer Code Review, Email Firms tab) passed the org dry run (146 of 146 tests) 2026-10-25; 4b.3 (shared issues decided together) built 2026-10-25; audit fixes part 1 passed the org dry run (159 of 159 tests) 2026-10-28. Next: 4c (cloud storage pull)."],
    ["Data", "All data is synthetic. Firms, advisors and funds are fictional."],
  ], [2400, 6960]),
);

add(H1("1. Executive summary"));
add(P("Wealth management firms that distribute funds through other dealers receive trade data from those dealers in inconsistent formats. Firm names are spelled differently, column names change between senders, dates are ambiguous, rep codes are reassigned without notice, and some teams share one code. Loaded blindly, this creates orphaned trades and duplicate advisors, and someone has to check a report after every run to find the damage."));
add(P("This solution replaces the blind load with a governed pipeline inside Salesforce. Files land automatically, each source's layout is mapped once and reused, deterministic rules resolve the clear-cut rows, and **Claude adjudicates only the ambiguous remainder**, showing its reasoning and the rules it relied on. A reviewer gets a notification, approves or corrects Claude's proposals in a Lightning Web Component, and can teach the system firm-specific rules. Only approved data loads, and every trade is split across the advisors who share its code."));
add(P("**The core idea:** humans handle exceptions instead of inspecting every run, and every decision makes the next import more automatic."));

add(H1("2. The business problem"));
add(H2("2.1 Current process"));
add(N("Dealers send trade files to the firm's data lake.", "num1"));
add(N("TALON picks the files up from the data lake, cleans them into a readable format and pushes them into Salesforce, attempting to match them.", "num1"));
add(N("The job runs with no human checkpoint.", "num1"));
add(N("Someone runs a report afterward to see what went wrong, then fixes records by hand.", "num1"));
add(H2("2.2 Issues reported by practitioners"));
add(...table(["Issue", "Example", "Effect when loaded blindly"], [
  ["Firm and branch names spelled differently", "Barder and Company / Barder and Co / Barder and C.", "Duplicate firm accounts; trades split across them"],
  ["Advisor rows missing their branch, firm or team", "Row contains only rep code and advisor name", "Orphaned trades with no parent"],
  ["Rep code reassigned to a new advisor, with no notice", "Code 2210 passes from one advisor to another at the same firm", "Trades credited to the wrong person, silently"],
  ["Multiple advisors share one code", "Team code split 60/40", "Credit given to one person, or totals double-counted"],
  ["Inconsistent column names and formats", "\"IA Code\" vs \"Dealer Rep #\"; DD/MM vs MM/DD; sells as negative amounts or as a SELL flag", "Values land in the wrong field or are dropped"],
  ["Advisors move firms", "Same person, new firm, new code", "Duplicate advisor records; career history lost"],
  ["Advisor codes never set up in Salesforce", "A trade arrives on a code that the separate code-setup intake never added", "Orphaned trades; the main cause of orphans, confirmed 2026-10-13"],
  ["Trades and AUM mixed in one file", "Each file carries both trade rows and AUM balance rows per rep code", "AUM rows treated as trades, or dropped"],
], [2600, 3380, 3380]));
add(H2("2.3 Trades, AUM and advisor codes (confirmed 2026-10-13)"));
add(B("**Trades:** dollar purchases and redemptions per fund (for example, $400,000 of Wealth World Fund Series A purchased). No units or prices."));
add(B("**AUM:** reported by the dealers themselves, per rep code, in every file, mixed in with the trade rows. AUM is a balance as of a date, so each new figure replaces the previous one for that code; it is never added up. (Superseded the 2026-10-12 assumption that AUM was calculated from trades as net sales; net sales remain available as a separate measure.)"));
add(B("**Advisor codes:** dealers send separate files listing advisor codes. Most orphan records came from codes never being set up from those files, not from bad matching."));
add(B("**Shared codes:** when a trade on a team code names one specific advisor, 100% of it goes to that advisor. Otherwise it splits by the team percentages."));

add(H1("3. Solution overview"));
add(H2("3.1 End-to-end flow"));
add(N("**Land.** A push job (simulating the data lake script) sends each raw file to a Salesforce REST endpoint. Duplicate files are rejected by hash.", "num2"));
add(N("**Normalize.** The file's header fingerprint selects a saved mapping profile for that source. Columns are mapped to canonical fields, dates parsed with the declared format, and direction normalized. Unknown layouts stop at Mapping Review, where Claude proposes a mapping for a person to confirm.", "num2"));
add(N("**Match, Tier 1.** Exact rep code and firm, inside the code's effective window, with a compatible advisor name and no reassignment signals.", "num2"));
add(N("**Match, Tier 2.** Scored fuzzy rules on names, firm and branch; auto-accept above a threshold.", "num2"));
add(N("**Match, Tier 3 (Claude).** Only unresolved rows, each with a short candidate list, go to Claude through the Salesforce Models API and Einstein Trust Layer. Claude returns structured JSON: decision, candidate, confidence, reasoning, flags and the IDs of rules it applied.", "num2"));
add(N("**Review.** A custom notification (desktop and mobile) opens the batch record, where an LWC shows each proposal for approval, rejection or correction. Approval is enforced in Apex with segregation of duties.", "num2"));
add(N("**Hold, never orphan.** A row on a code that is unknown, ended or dormant is held, and a Code Follow-Up is created on a to-do list for someone to find out who the code belongs to. Claude suggests a likely answer. When the code is set up (by a code roster file or by hand), held rows are re-matched automatically and the follow-up closes.", "num2"));
add(N("**Load and allocate.** Approved trade rows become Trades, split into Trade Allocations by the code's assignments on the trade date, or 100% to one advisor when the row names a single team member. Approved AUM rows become AUM Snapshots that replace the previous figure for the same code and date, split the same way.", "num2"));
add(N("**Learn.** Reviewer overrides can become Matching Rules (two-person approval) that Claude must consider and cite in future batches. Approved matches also update the alias tables and crosswalk, so the same question is never asked twice.", "num2"));
add(H2("3.2 Design principles"));
add(B("**Deterministic first, Claude second.** Rules resolve the clear cases cheaply and repeatably; Claude adjudicates only ambiguity."));
add(B("**Claude never writes data.** Every Claude output is a proposal validated by Apex and approved by a person."));
add(B("**Nothing is silently dropped.** Every column is mapped or explicitly ignored; row counts and amounts reconcile in and out."));
add(B("**Explainable by default.** Every decision stores its input, output, model, prompt version, rules applied and reviewer."));
add(B("**History is preserved, not rewritten.** Allocation percentages are snapshotted at load; end dates and rules are retired, never deleted."));

add(H1("4. Data architecture"));
add(H2("4.1 Model"));
add(...CODE([
  "Firm (Account)",
  " |-- Branch (child Account, ParentId)",
  " |     '-- Advisor (Contact)          current home only",
  " |",
  " |-- Firm Alias  ---------------------> Firm (Account)",
  " '-- Rep Code",
  "       |-- Rep Code Assignment -------> Advisor   (who, %, effective dates)",
  "       |-- Trade --------------------> Fund (Product2)",
  "       |     '-- Trade Allocation ----> Advisor   (% and $ snapshot)",
  "       |-- AUM Snapshot -------------> Fund (optional)   (balance as of a date)",
  "       |     '-- AUM Allocation ------> Advisor",
  "       '-- Code Follow-Up (also for codes not yet in Salesforce)",
  "",
  "Fund (Product2) <-- Fund Alias",
  "",
  "Mapping Profile <-- Import Batch --< Import Staging Row      (ingestion, phase 2)",
  "Import Batch --< ContentVersion (the raw file)",
  "Learning  (phase 3):  Matching Rule",
]));
add(H2("4.2 Object catalogue"));
add(...table(["Object", "Purpose", "Key relationships", "Phase"], [
  ["Account (standard)", "Firms and branches", "Branch.ParentId = Firm", "1"],
  ["Contact (standard)", "Advisors; AccountId is the current branch or firm only", "Child of branch Account", "1"],
  ["Product2 (standard)", "Funds", "Referenced by Trade and Fund Alias", "1"],
  ["Rep_Code__c", "A dealer code issued by a firm", "Lookup to Firm; parent of Assignments and Trades", "1"],
  ["Rep_Code_Assignment__c", "Who holds a code, at what %, during which dates", "Master-detail to Rep Code; lookup to Advisor", "1"],
  ["Trade__c", "One fund purchase or redemption", "Lookup to Rep Code and Fund", "1"],
  ["Trade_Allocation__c", "One advisor's snapshotted share of a trade", "Master-detail to Trade; lookup to Advisor", "1"],
  ["Firm_Alias__c", "Approved firm/branch name variants", "Lookup to Account", "1"],
  ["Fund_Alias__c", "Approved fund name variants", "Lookup to Product2", "1"],
  ["Import_Batch__c", "One received file and its lifecycle", "Parent of Staging Rows; lookup to Mapping Profile", "2"],
  ["Import_Staging_Row__c", "One raw and normalized row awaiting matching", "Master-detail to Import Batch", "2"],
  ["Mapping_Profile__c", "Saved column mapping and formats per source layout", "Referenced by Import Batch", "2"],
  ["Matching_Rule__c", "Reviewer-taught guidance or normalization rules", "Lookup to originating Staging Row", "3"],
  ["Code_Follow_Up__c", "To-do item for a code that is unknown, ended, dormant, suspected reassigned or incompletely split", "Lookup to Rep Code (when it exists) and Firm; held staging rows look up to it", "3"],
  ["AUM_Snapshot__c", "A dealer-reported AUM balance per rep code (and fund, when given) as of a date", "Lookup to Rep Code, Fund and Import Batch", "4"],
  ["AUM_Allocation__c", "One advisor's share of an AUM snapshot", "Master-detail to AUM Snapshot; lookup to Advisor", "4"],
], [2300, 3000, 3160, 900]));
add(H2("4.3 Key design decisions"));
add(...table(["Decision", "Why"], [
  ["Rep codes hang off the firm, not the advisor", "Firms issue codes; codes are reassigned and shared, so a code cannot belong to one person."],
  ["Assignments are a junction with % and effective dates", "Handles moves, silent reassignments and shared codes with one structure. A solo advisor is one assignment at 100%."],
  ["Matching targets the code; the split is mechanical", "Claude decides which code a row belongs to, never the percentages or the math."],
  ["Allocation % and $ are snapshotted on Trade Allocation", "Re-splitting a team later must not rewrite historical credit."],
  ["Allocations round down, remainder to the largest share", "Allocations always sum exactly to the trade, so reconciliation ties out."],
  ["Amount is always positive; direction is a picklist", "Firms signal direction differently; one convention after normalization. Signed Amount drives net sales."],
  ["AUM is stored as dated snapshots that replace, not accumulate", "Dealers report AUM as a balance per rep code in every file; re-sent files must not double-count. Net sales remain a report on Trade Allocation."],
  ["Unknown or ended codes hold rows and raise a follow-up", "Orphans came from codes never being set up; holding the trade and asking a person to get the information fixes the cause, not the symptom."],
  ["Single named team member gets 100% of a trade", "Confirmed business rule; otherwise team percentages apply."],
  ["History is the same Trade object, filtered by date", "A separate historical object would split every report and double the logic. Archiving is a storage decision for later."],
  ["Contact.AccountId is the current firm only", "Career history is reconstructed from Rep Code Assignments."],
  ["Product2 lookups are optional at field level", "Salesforce does not allow required or delete-restricted lookups to Product2; validation rules enforce the value instead."],
], [3400, 5960]));

add(H2("4.4 Field dictionary"));
for (const obj of Object.keys(OBJ_LABEL)) {
  const ph = spec.fields.find((x) => x.obj === obj).phase;
  add(H3(`${OBJ_LABEL[obj]} (${obj}), phase ${ph}`));
  for (const f of spec.fields.filter((x) => x.obj === obj)) {
    add(fieldBlock({ name: f.label, api: f.api, type: typeText(f), desc: f.desc, help: f.help }));
  }
}
add(H2("4.5 Validation rules"));
add(...table(["Object", "Rule", "Condition", "Purpose"], spec.vrs.map((v) => [v.obj, v.name, v.formula, v.desc]), [2000, 2200, 2700, 2460]));
add(P("Note: percent fields evaluate as decimals in formulas (100% = 1) but as whole numbers in Apex and the API (100)."));

add(H1("5. Technical design"));
add(H2("5.1 Ingestion (phase 2, built)"));
add(...table(["Component", "Responsibility"], [
  ["push_job.py (Python)", "Polls datalake/inbox/<FIRM>/; sends each raw file with its SHA-256 hash; moves it to processed/ or failed/ (with the reason); leaves it for retry on network or 5xx errors; re-authenticates once on 401. Auth: Salesforce CLI login (demo) or JWT bearer through an External Client App (production)."],
  ["TradeIngestResource (Apex REST)", "POST /services/apexrest/trade-import/v1/files. Validates the request, recomputes the hash server-side, returns the existing batch for a duplicate file (200), creates the Import Batch and attaches the file (201), queues processing. Rejects files over 1 MB before decoding to protect the heap."],
  ["ImportBatchProcessor (Queueable)", "Processes only Received batches (re-queues are harmless). Parses the file, fingerprints the header, picks the Active profile, resolves columns, normalizes every row, inserts staging rows. All-or-nothing via a savepoint. Outcomes: Staged, Mapping Review, Failed."],
  ["CsvParser", "RFC 4180 parsing with quoted values, embedded delimiters and line breaks, CRLF or LF, byte order mark, and comma/semicolon/tab auto-detection. Linear time using cached indexOf positions."],
  ["MappingService", "Header fingerprint (SHA-256 of normalized headers), Active profile lookup with firm tie-break, and column resolution that reports every problem at once."],
  ["TradeRowNormalizer", "Per-row rules: rep code clean-up, strict date parsing by declared format, amount parsing (currency, parentheses, signs, period or comma decimals), direction by type column or sign, required fields, field lengths, column count. Errors are recorded on the row, never thrown."],
  ["ProductDeleteGuard + Product2Trigger", "Blocks deleting a fund that trades reference, replacing the delete-restrict option Salesforce does not allow on Product2 lookups."],
], [2700, 6660]));
add(P("**Batch statuses:** Received (endpoint) > Staged (rows normalized, ready for matching) or Mapping Review (no Active profile, or an incomplete one; Error Message lists every problem) or Failed (unreadable file; Error Message says why). Later statuses are used from phase 3."));
add(P("**Security:** all queries run WITH USER_MODE and all DML runs as user, so object and field permissions are enforced. The push job's user needs only the Trade Import Integration permission set. The delete guard deliberately runs in system mode so it can see every trade."));
add(P("**Limits:** 1 MB and 5,000 data rows per file (heap and CPU headroom); UTF-8 only. A 5,000-row parse is covered by a test with a CPU assertion."));
add(H2("5.2 Name normalization"));
add(P("NameNormalizer.firmKey() lowercases, converts \"&\" to \"and\", keeps Unicode letters and digits, collapses spaces and repeatedly strips legal suffixes from the end (including French forms such as \"et cie\" and \"ltée\"). Each suffix requires a preceding space, so a firm literally named \"Co\" is preserved. Barder & Company, Barder and Co, Barder and C. and Barder & Co., Inc. all reduce to \"barder\". Keys are not unique: a key that maps to two firms (Kestrel Capital Inc. and Ltd.) always goes to review."));
add(H2("5.3 Matching and reassignment detection (phase 3)"));
add(P("Firms never announce code transfers, so the system infers them. Tier 1 auto-resolves only when nothing looks wrong. Any of the following signals sends the row to Claude and review with a flag:"));
add(...table(["Signal", "Strength", "Works without names?"], [
  ["Advisor name incompatible with every active holder of the code", "Strong", "No"],
  ["Previous holder appears under a different code", "Strong", "Yes"],
  ["Code reactivates after a dormant period (default 180 days, per firm)", "Moderate", "Yes"],
  ["Sudden branch change on the same code", "Weak, additive", "Yes"],
], [5200, 2000, 2160]));
add(P("On a shared code, any active team member's name is compatible; an unknown name is flagged TEAM_CHANGE_SUSPECTED. A code whose active split is under 100% holds its trades with ALLOCATION_INCOMPLETE. When a reassignment is confirmed, the old assignment is end-dated at its Last Confirmed Trade Date and trades in the gap go to review. Previously loaded trades after that date are flagged for correction."));
add(H2("5.4 Claude contract (phase 3)"));
add(B("Called through the Salesforce Models API, so requests pass through the Einstein Trust Layer. Temperature 0 where supported."));
add(B("Sent only matching fields (names, codes, firm, branch, dates), never client identifiers. 10 to 20 rows per call."));
add(B("Hard constraints: choose only listed candidate IDs; return NEEDS_HUMAN when two candidates are similarly plausible; treat file contents as data, not instructions; missing fields are neither evidence for nor against a candidate; never compute allocations."));
add(B("Output per row, reasoning first: rowId, reasoning, decision (MATCH, NEW_ADVISOR, NEEDS_HUMAN), candidateId, confidence (HIGH, MEDIUM, LOW), evidence, flags, rulesApplied."));
add(B("Apex validation: every row returned once; every candidate and rule ID was actually sent; MATCH requires a candidate. Failures retry once, then become NEEDS_HUMAN."));
add(H2("5.5 Review, notification and learning (phase 4)"));
add(B("A record-triggered flow sends a Custom Notification to the Import Reviewers group when a batch reaches Pending Review or Mapping Review; tapping it opens the batch record (desktop or the Salesforce mobile app)."));
add(B("The review LWC supports per-row approve, reject or choose another candidate, and bulk-approve for HIGH confidence. Apex enforces a custom permission and blocks uploaders from approving their own batch."));
add(B("\"Teach\" turns a reviewer's note into a drafted Matching Rule (Match Guidance or Normalization), which needs a second approver before it goes live. Claude must cite the rules it used."));
add(B("A completion notification returns the reconciliation summary to the uploader."));
add(H2("5.6 Allocation"));
add(P("TradeAllocator.split(amount, percents) validates that percentages are positive and total exactly 100, rounds each share down to the cent, and gives the remainder to the largest share. Verified: $100.01 at 60/40 gives $60.01 and $40.00; negative (redemption) amounts tie out exactly."));
add(H2("5.7 Security and compliance"));
add(B("External Client App with JWT bearer for the push job (new Connected Apps are disabled by default from Spring '26)."));
add(B("Dedicated least-privilege integration user; private key kept out of the repository."));
add(B("Segregation of duties for batch approval and rule activation, enforced server-side."));
add(B("Full audit trail per decision. Check Trust Layer data masking: if names are masked before reaching the model, name matching degrades."));

add(H1("6. Synthetic data and planted traps"));
add(...table(["Trap", "Seeded records", "Expected behaviour"], [
  ["Firm name variants", "Barder & Company", "Variants normalize to \"barder\" and resolve automatically"],
  ["Accents dropped in files", "Lumière Valeurs Mobilières Ltée + unaccented alias", "Resolved through the alias table"],
  ["Two firms, one key, same code", "Kestrel Capital Inc. and Ltd., both code 1001", "Never auto-resolved; review decides"],
  ["Advisor moved firms", "Julia Morales: Northgate 3102 (ended 2024-05-28), then Barder 457", "Trades before and after the move credited correctly"],
  ["Silent code reassignment", "Barder 2210 held by Marcus Bell since 2018", "A new name on 2210 is flagged CODE_REASSIGNMENT_SUSPECTED"],
  ["Dormant code", "Northgate 5521, last trade 2025-02-03", "Next trade flagged for review"],
  ["Shared code", "Lumière 7700, 60/40", "Each trade split into two allocations"],
  ["Incomplete split", "Northgate 8800 at 80% after Sam Whitford left", "Trades held with ALLOCATION_INCOMPLETE"],
  ["Ambiguous fund", "\"ETF Wealth World Fund A\" deliberately not aliased", "Routed to review: ETF or Series A?"],
], [2300, 3600, 3460]));

add(H1("7. Verification process"));
add(P("Language semantics are verified, not assumed: Apex differs from Java in places (String.valueOf(null) returns null; String.isBlank is true for a tab), and the lint encodes each difference found. Every code delivery passes these checks before it is presented for deployment. Each check is proven to work with a deliberate-error control (it must fail on a planted mistake). The Python port must mirror every guard in the Apex, including input validation, not just the happy-path logic."));
add(...table(["Check", "What it catches", "Tool"], [
  ["1. Syntax", "Any Apex that would not parse", "Salesforce's Apex parser (via prettier-plugin-apex)"],
  ["2. Static analysis", "SOQL/DML in loops, missing CRUD/FLS enforcement, sharing gaps, injection, error-prone code", "PMD 7 (security, performance, error-prone, best-practice categories)"],
  ["3. Logic cross-check", "Wrong expected values in tests; logic bugs in parsing and normalization", "Python port of the logic run against the same shared vectors that generate the Apex tests; sample files simulated end to end"],
  ["4. Metadata consistency", "Fields referenced in Apex, SOQL (including parent-child subqueries), constructors, layouts, list views or permission sets that do not exist or are on the wrong object; child relationship names; user-mode updates that would send fields that can never be edited (added after the phase 3A org gate); field permissions on required fields; platform length limits and fields not allowed on layouts (added after the 3B org gate); known platform restrictions", "Custom cross-reference script"],
  ["5. Apex runtime lint", "Code that parses and passes PMD but fails on the platform: Assert messages that can be null, String.isBlank on whitespace-significant values (added after the phase 2 org gate), files starting with a byte order mark (added after the model test script failed). Understands generic type arguments such as Map<String, String> (added in 3B after a false positive). Rejects identifiers Apex will not compile, such as a trailing or double underscore (added after the 3B org gate)", "Custom lint script"],
  ["6. Manual review", "Type mismatches, governor limits, null handling, error paths, sharing and security", "Line-by-line checklist"],
  ["7. Push job tests", "Upload, move, retry, re-authentication and JWT behaviour", "Python unittest with a mocked endpoint"],
  ["Org gate", "Compilation against the org's schema, tests passing on the platform, and per-class coverage", "sf project deploy start --dry-run --verbose --test-level RunSpecifiedTests, before every real deploy"],
], [2000, 4360, 3000]));

add(H1("8. Build phases"));
add(...table(["Phase", "Scope", "Status"], [
  ["1. Data model and seed data", "Objects, fields, validation rules, layouts, list views, permission set, synthetic seed data", "Deployed and verified " + today],
  ["2. Ingestion", "Import Batch, Staging Row, Mapping Profile; REST endpoint; CSV parsing; NameNormalizer; normalization; Product2 delete guard; Python push job; synthetic trade files", "Deployed and verified end to end 2026-10-13"],
  ["3A. Deterministic matching", "Firm, code, advisor and fund matching; AUM rows and roster feed; Code Follow-Up to-do list with automatic re-matching", "Deployed and verified end to end 2026-10-14"],
  ["3B. Claude", "Models API service (Claude Sonnet 5), suggestions on Needs Review rows and follow-ups, mapping proposals, Matching Rule object, roster approval, response validation", "Org gate passed 2026-10-15 (108 of 108 tests)"],
  ["4. Review and load", "Review LWC, notifications, approval controls, TradeAllocator load, reconciliation, Teach flow, Lightning app and tabs", "Planned"],
  ["5. Demo", "Scripted run, video, repository clean-up for publishing", "Planned"],
], [2400, 5160, 1800]));
add(H1("9. Phase 1 build record"));
add(H2("9.1 Delivered"));
add(B("6 custom objects, 23 custom fields, 6 validation rules, 6 page layouts, 6 list views."));
add(B("Permission set Trade_Import_Admin (object CRUD with View/Modify All; field permissions on all non-required fields)."));
add(B("60 seed records: 5 firms, 6 branches, 10 advisors, 5 funds, 8 rep codes, 11 assignments, 7 firm aliases, 8 fund aliases."));
add(H2("9.2 Deployment commands"));
add(...CODE([
  "sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run",
  "sf project deploy start --source-dir force-app --target-org tradeDemo",
  "sf org assign permset --name Trade_Import_Admin --target-org tradeDemo",
  "sf data import tree --plan data/seed-plan.json --target-org tradeDemo",
]));
add(H2("9.3 Issues and resolutions"));
add(...table(["Issue", "Cause", "Resolution"], [
  ["Deploy failed: \"Cannot add a lookup relationship child with cascade or restrict options to Product2\"", "Lookups to Product2 cannot be required or delete-restricted", "Made Fund lookups optional (clear on delete) and added Fund_Required validation rules. A Product2 delete guard trigger is planned for phase 2."],
  ["Seed import: plan file not found", "The data folder was not at the project root", "Moved data to the project root"],
  ["Warning: saveRefs/resolveRefs ignored", "Current CLI resolves references automatically", "Harmless; properties will be dropped from future plans"],
  ["git not recognized", "Git not installed; then terminal PATH not refreshed after install", "Installed with winget; refreshed PATH in the session"],
], [3000, 2800, 3560]));
add(H2("9.4 Verification"));
add(P("Query: SELECT Name, Firm__r.Name, Active_Allocation_Total__c FROM Rep_Code__c"));
add(...table(["Code", "Firm", "Active total", "Expected"], [
  ["2210", "Barder & Company", "100", "Yes"],
  ["457", "Barder & Company", "100", "Yes"],
  ["1001", "Kestrel Capital Inc.", "100", "Yes"],
  ["1001", "Kestrel Capital Ltd.", "100", "Yes"],
  ["7700", "Lumière Valeurs Mobilières Ltée", "100", "Yes"],
  ["3102", "Northgate Wealth Partners Inc.", "0", "Yes: Julia's assignment end-dated"],
  ["5521", "Northgate Wealth Partners Inc.", "100", "Yes"],
  ["8800", "Northgate Wealth Partners Inc.", "80", "Yes: incomplete split trap"],
], [1100, 3400, 1500, 3360]));

add(H1("10. Phase 2 build record"));
add(H2("10.1 Delivered"));
add(B("3 custom objects (Import Batch, Import Staging Row, Mapping Profile), 29 fields, 3 validation rules, layouts and list views."));
add(B("7 Apex classes and 1 trigger: TradeIngestResource, ImportBatchProcessor, CsvParser, MappingService, TradeRowNormalizer, NameNormalizer, ProductDeleteGuard, Product2Trigger."));
add(B("9 test classes (TestDataFactory plus 8 suites); 3 of them generated from shared vectors. Integration tests run as a Standard User holding only the Trade Import Integration permission set, proving least privilege."));
add(B("Permission sets: Trade_Import_Admin updated with the new objects and Apex class access; new Trade_Import_Integration for the push job's user."));
add(B("Python push job with sf CLI and JWT authentication, key generator, 11 unit tests, and JWT setup guide."));
add(B("Synthetic data lake: four firm files and a mapping profile seed script generated from one definition."));
add(H2("10.2 Sample files and expected outcomes"));
add(...table(["Firm", "Format", "Planted traps", "Expected"], [
  ["BARDER", "Comma CSV, CRLF, byte order mark, MM/DD/YYYY, signed amounts with $ and commas", "Leading-zero code 0457; firm as \"Barder and Co\"/\"Barder and C.\"; code 2210 reassigned to Priya Nair; ambiguous \"ETF Wealth World Fund A\"; quoted value with a comma; missing amount", "Staged, 7 rows, 1 error"],
  ["NORTHGATE", "Comma CSV, LF, DD/MM/YYYY, BUY/SELL type column", "Team code 8800 (80% split); 13/09 and 03/09 dates; dormant code 5521; Julia's old code 3102 in 2024; 31/09/2026; SWITCH", "Staged, 7 rows, 2 errors"],
  ["LUMIERE", "Semicolon CSV, French headers, YYYY-MM-DD, decimal commas with no-break-space thousands, ACHAT/RACHAT", "Accents dropped in firm name; shared code 7700 with both names on one row; blank firm filled from the feed", "Staged, 4 rows, 0 errors"],
  ["KESTREL", "Unknown layout", "\"Kestrel Capital\" matches two firms; both use code 1001", "Mapping Review"],
], [1300, 2900, 3460, 1700]));
add(H2("10.3 Verification report"));
add(...table(["Check", "Result"], [
  ["Syntax", "17 of 17 Apex files parse (negative control: a missing semicolon is caught)"],
  ["Static analysis", "0 findings in PMD security, performance and error-prone categories. Style-only findings: missing ApexDoc tags, complexity notices, test-style rules, and 2 false positives where asserts live in helper methods"],
  ["Logic cross-check", "85 shared vectors pass in the Python port (17 name keys, 18 dates, 15 amounts, 6 rep codes, 8 types, 16 CSV cases, 5 delimiters); 2 header fingerprints computed in Python are asserted byte-for-byte in Apex; all 4 sample files produce their planted outcomes"],
  ["Metadata consistency", "0 problems across 18 code files and 52 fields on 9 objects (negative controls: a misspelled field and a field from the wrong object in SOQL are both caught)"],
  ["Manual review", "3 issues found and fixed before delivery (see 10.4)"],
  ["Push job tests", "11 of 11 pass, including real RS256 signing and verification of the JWT claims"],
  ["Phase 1 regression", "Regenerated phase 1 metadata is byte-identical apart from the permission set's new class access"],
  ["Apex runtime lint", "0 problems (negative control: flags all 3 lines that failed in the org)"],
  ["Org gate, run 1", "All 107 components compiled; 41 of 45 tests passed. 4 failures from 2 bugs (see 10.4), fixed"],
  ["Org gate, run 2", "Delimiter fix confirmed (CsvParser 100% covered). The assert fix was wrong (see 10.4); 3 failures repeated. Per-class coverage: CsvParser, MappingService, NameNormalizer, ProductDeleteGuard, Product2Trigger 100%; TradeRowNormalizer 99%; ImportBatchProcessor 96%; TradeIngestResource 83%"],
  ["Org gate, run 3", "Passed: 45 of 45 tests, 107 components. Deployed with RunSpecifiedTests"],
  ["End-to-end run", "Push job sent 4 files (4 SENT, 0 failed). Results matched expectations exactly: BARDER Staged 7 rows/1 error; KESTREL Mapping Review; LUMIERE Staged 4/0; NORTHGATE Staged 7/2"],
], [2400, 6960]));
add(H2("10.4 Issues found during verification and the org gate"));
add(...table(["Found by", "Issue", "Fix"], [
  ["Negative control", "The cross-reference checker read apostrophes in comments (\"profile's\") as string literals, hiding code from the check", "Comments and strings are now stripped in one pass; both negative controls caught"],
  ["Manual review", "Tests compared Integer literals to Decimal fields; equality across numeric types is not guaranteed", "Asserts use intValue() or decimal literals"],
  ["Manual review", "A relationship field was set inside an SObject constructor", "Assigned after construction"],
  ["Manual review", "An aggregate query sat directly in a for loop, which fails on large results", "Query assigned to a list first"],
  ["Design review", "A 2 MB upload limit would exceed the 6 MB heap once the body, its parse and the decoded file coexist", "Limit set to 1 MB (about 5,000 rows) and checked before decoding"],
  ["Design review", "Test outcomes could depend on the org's Account sharing defaults", "The integration test user creates its own firm Account"],
  ["Org gate", "CsvParser rejected a tab delimiter: String.isBlank('\\t') is true in Apex, so tab-delimited files would have failed. The Python port had no delimiter check, so the vector test could not catch it", "Check for null and length instead; port now mirrors the guard; vectors added for tab, space, empty and two-character delimiters"],
  ["Org gate", "Three tests passed their assertions but threw NullPointerException: Apex Assert methods reject a null message, and the message was a field that is null on success", "First fix (String.valueOf) was wrong: unlike Java, String.valueOf(null) returns null in Apex. Final fix: every message contains a literal ('errors: ' + value). The lint now accepts only messages containing a literal, and flags the failed fix"],
  ["Org gate", "Org-wide coverage 51% below the 75% required for RunLocalTests, caused by six Apex classes already in the org (BookOfBusinessController and Agentforce action classes) with no tests", "Deploy with RunSpecifiedTests listing this project's 8 test classes; Salesforce then requires 75% per deployed class, which every class meets"],
], [1800, 4100, 3460]));
add(H2("10.5 Runbook"));
add(...CODE([
  "sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests <8 test classes>",
  "sf project deploy start --source-dir force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests <8 test classes>",
  "sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo",
  "cd pushjob; python -m venv .venv; .venv\\Scripts\\Activate.ps1; pip install -r requirements.txt",
  "python push_job.py --lake ..\\datalake --once --auth sfcli --target-org tradeDemo",
]));


add(H1("11. Phase 3 and 4 design update (2026-10-13)"));
add(P("Confirmed with a practitioner: (1) files mix trade rows and AUM rows; (2) AUM is per rep code; (3) AUM comes in every file; (4) advisor codes arrive in separate files, and unknown or old codes should create a to-do list for follow-up; (5) a trade naming one member of a team code goes 100% to that person; (6) the flow is data lake to TALON (cleanup) to Salesforce."));
add(H2("11.1 Changes by component"));
add(...table(["Component", "Change"], [
  ["Mapping profiles", "New Feed Type (Trade Activity or Advisor Code Roster). Trade Activity profiles get an AUM indicator list: the values that mark a row as AUM, read from a row type column when mapped, otherwise from the transaction type column."],
  ["Normalizer", "Classifies each row as Trade, AUM or Code Roster. AUM rows: no direction, value must be zero or more. Roster rows: code, advisor, firm, branch and effective date required."],
  ["Staging rows", "New Row Type, Source Branch Name, Credited Advisor and Code Follow-Up fields. The date field is relabelled Row Date (trade date, AUM as-of date or code effective date)."],
  ["Matching (phase 3)", "Codes not found, or found only with ended assignments or dormant, hold the row and open or update one Code Follow-Up per firm and code. A trade naming one active team member is credited 100% to them."],
  ["Code roster feed (phase 3)", "Roster rows propose new Rep Codes and Assignments for review. Approval resolves matching follow-ups and re-matches their held rows automatically."],
  ["Loading (phase 4)", "AUM rows upsert AUM Snapshots on a unique key of code, fund and as-of date, so a re-sent figure replaces rather than adds. Each snapshot is split into AUM Allocations by the assignments in effect on its as-of date."],
], [2400, 6960]));
add(H2("11.2 Field definitions"));
add(P("The definitions below are generated from the built metadata (doc/dump_fields.py), so they always match what is deployed. Phase 3A fields are listed in section 12.4."));
add(H3("Mapping Profile (Mapping_Profile__c), additions"));
live.Mapping_Profile__c.forEach((f) => add(fieldBlock(f)));
add(H3("Import Staging Row (Import_Staging_Row__c), additions and changes"));
live.Import_Staging_Row__c.filter((f) => ["Row_Type__c", "Source_Branch_Name__c", "Credited_Advisor__c", "Code_Follow_Up__c"].includes(f.api)).forEach((f) => add(fieldBlock(f)));
add(fieldBlock({ name: "Row Date (relabelled)", api: "Trade_Date__c", type: "Date (existing field, label changed only)", desc: "Date from the row, parsed with the profile's date format: the trade date for Trade rows, the as-of date for AUM rows, or the effective date for Code Roster rows. API name kept to avoid breaking deployed code.", help: "The trade date, AUM as-of date or code effective date, depending on the row type." }));
add(H3("Code Follow-Up (Code_Follow_Up__c), new object, record name CFU-{00000}"));
live.Code_Follow_Up__c.forEach((f) => add(fieldBlock(f)));
add(H3("AUM Snapshot (AUM_Snapshot__c), new object, phase 4"));
add(fieldBlock({ name: "Rep Code", api: "Rep_Code__c", type: "Lookup(Rep Code), required, delete restricted", desc: "The code the dealer reported this AUM under.", help: "The dealer code this balance was reported for." }));
add(fieldBlock({ name: "Fund", api: "Fund__c", type: "Lookup(Product2), optional, clear value if deleted", desc: "The fund, when the dealer breaks AUM down by fund. Blank means a total for the code across all funds.", help: "The fund, if this balance is for a single fund." }));
add(fieldBlock({ name: "As Of Date", api: "As_Of_Date__c", type: "Date, required", desc: "Date the balance applies to, from the row date. The latest snapshot per code (and fund) is the current AUM.", help: "The date this balance applies to." }));
add(fieldBlock({ name: "Market Value", api: "Market_Value__c", type: "Currency(16,2), required", desc: "Balance reported by the dealer. Zero or more; replaced, never summed, when a newer or re-sent figure arrives for the same key.", help: "The AUM balance reported by the dealer." }));
add(fieldBlock({ name: "Snapshot Key", api: "Snapshot_Key__c", type: "Text(255), Unique, External ID", desc: "Rep code record, fund (or ALL) and as-of date joined. The load upserts on this key so a re-sent file replaces the figure instead of adding a second one.", help: "System-generated. Do not edit." }));
add(fieldBlock({ name: "Import Batch", api: "Import_Batch__c", type: "Lookup(Import Batch), clear value if deleted", desc: "The batch that most recently set this value, for traceability back to the source file.", help: "The import that supplied this balance." }));
add(H3("AUM Allocation (AUM_Allocation__c), new object, phase 4"));
add(fieldBlock({ name: "AUM Snapshot", api: "AUM_Snapshot__c", type: "Master-Detail(AUM Snapshot)", desc: "The snapshot being allocated. Allocations are deleted and rebuilt when the snapshot is replaced.", help: "The AUM balance this share belongs to." }));
add(fieldBlock({ name: "Advisor", api: "Advisor__c", type: "Lookup(Contact), required", desc: "The advisor credited with this share of the AUM. Advisor-level AUM reporting must use this object.", help: "The advisor credited with this share." }));
add(fieldBlock({ name: "Allocation Percent", api: "Allocation_Percent__c", type: "Percent(3,2), required", desc: "Snapshot of the advisor's share on the as-of date, from the code's assignments in effect then.", help: "The advisor's share of this balance." }));
add(fieldBlock({ name: "Allocated Value", api: "Allocated_Value__c", type: "Currency(16,2), required", desc: "This advisor's share of Market Value, calculated by TradeAllocator so shares sum exactly to the snapshot.", help: "The dollar value of AUM credited to this advisor." }));
add(H2("11.3 Synthetic data additions"));
add(B("AUM rows mixed into each sample firm file, marked the way each firm would (for example a POSITION transaction type or an AUM row type column)."));
add(B("A code roster file for one firm, including the code for the new advisor on reassigned code 2210, so the follow-up can be resolved live in the demo."));
add(B("A trade on team code 8800 that names a single member, to show the 100% rule, and rows on unknown and dormant codes to fill the follow-up list."));
add(B("A datalake/samples folder with pristine copies and a reset script, so the demo can be re-run."));

add(H1("12. Phase 3A build record (2026-10-14)"));
add(H2("12.1 What it does"));
add(P("Every staged row is now matched automatically, straight after staging. Matching answers four questions in order: which firm, which rep code, who gets the credit on that date, and which fund. Each row ends in one of four places: **Matched** (ready to load), **Needs Review** (a person must choose, for example between two similar firms), **Held** (the code information is missing or stale) or **Invalid** (bad data from validation)."));
add(P("Held rows are the fix for orphans. Instead of loading a trade against a code nobody has set up, or crediting the wrong advisor after a silent transfer, the row waits on a **Code Follow-Up**: one to-do per firm, code and reason, showing how many rows and dollars are waiting. When someone resolves it, the held rows are released and re-matched automatically. Nothing is lost, and nothing is guessed."));
add(P("No Claude calls yet. 3A is rule-based on purpose: it is predictable, fully tested, and gives a baseline. In 3B, Claude works only on what these rules leave in Needs Review or on a follow-up."));
add(H2("12.2 How matching works"));
add(P("ImportBatchProcessor stages the file, then queues TradeMatcher as its own job (each stage gets full governor limits). TradeMatcher loads all reference data the batch needs in a fixed number of queries (aliases, codes with their assignments, and advisors for roster rows), then decides each row in memory, so cost does not grow with row count."));
add(...table(["Step", "Rule", "Outcome when it fails"], [
  ["1. Firm", "Normalized firm name looked up in Firm Alias. If no exact key, the closest alias is accepted when similarity is 0.9 or more and leads the runner-up by 0.1", "Needs Review: FIRM_MISSING, FIRM_UNRESOLVED or FIRM_AMBIGUOUS, with the closest candidates saved"],
  ["2. Code", "Rep code looked up at the matched firm", "Held, Unknown Code"],
  ["3. Active on the date", "At least one assignment covers the row date", "Held, Code Ended; or Needs Review DATE_BEFORE_CODE_START"],
  ["4. Named advisor", "If the row names someone, they must match an active holder (last name, plus first name or initial; accents ignored)", "Held, Reassignment Suspected (REASSIGNMENT_SUSPECTED, or TEAM_CHANGE_SUSPECTED on a team code)"],
  ["5. Dormancy", "No name and more than 180 days since the code's last confirmed trade", "Held, Code Dormant. With a confirming name the row matches and is flagged DORMANT_CODE_REACTIVATED"],
  ["6. Credit", "One named holder gets 100% (SINGLE_ADVISOR_CREDIT); a solo code goes to its holder; otherwise the team split applies (TEAM_SPLIT)", "Held, Allocation Incomplete when active shares do not total 100%"],
  ["7. Fund", "Fund Alias exact key, else the same fuzzy rule as firms (FUND_FUZZY). Optional for AUM rows", "Needs Review: FUND_UNRESOLVED or FUND_AMBIGUOUS"],
], [1500, 4560, 3300]));
add(P("Roster rows are classified rather than loaded: ROSTER_CONFIRMS (already the holder), ROSTER_NEW_HOLDER (code exists, different person), ROSTER_NEW_CODE, plus NEW_ADVISOR or ADVISOR_AMBIGUOUS. Approving them comes in 3B."));
add(P("Follow-ups are upserted on Follow-Up Key (source firm, code, reason). CodeFollowUpService recounts held rows and held trade value with two aggregate queries. A trigger on Code Follow-Up handles status changes: Resolved releases the rows to Pending and queues TradeMatcher; Closed - No Action sends them to Needs Review with FOLLOW_UP_CLOSED. If a resolved code is still broken, the rows are held again and the follow-up reopens."));
add(H2("12.3 Delivered"));
add(B("New object Code Follow-Up (11 fields, layout, list view, tab). 12 new Import Staging Row fields, 3 new Import Batch roll-ups, 2 new Mapping Profile fields. Totals: 10 objects, 80 fields, 9 validation rules."));
add(B("New Apex: NameMatcher (name compatibility and similarity), TradeMatcher (queueable matcher), CodeFollowUpService, CodeFollowUpTrigger. Updated: MappingService (feed types, AUM indicators), TradeRowNormalizer (row types, AUM and roster validation), ImportBatchProcessor (queues matching)."));
add(B("Tests: TradeMatcherTest (edge cases), NameMatcherTest (generated from shared vectors), DemoScenarioTest (generated: runs every sample file and asserts every row and follow-up), plus extended MappingServiceTest and TradeRowNormalizerTest. 11 test classes in all."));
add(B("Samples: Barder file with AUM rows, Northgate with Branch, Lumière with SOLDE balances, a Barder advisor code roster file; datalake/samples with a reset script."));
add(B("Scripts: seed-mapping-profiles (upserts by name), reset-imports, demo-resolve-2210 (plays the firm confirming the reassignment), reset-demo.ps1 with a -Roster switch."));
add(B("Integration permission set: read on Account, Contact and Product2 (with Parent Account and Contact Account), because matching runs as the pushing user in user mode."));
add(H2("12.4 Field definitions (generated from the built metadata)"));
add(H3("Import Staging Row: matching results"));
live.Import_Staging_Row__c.filter((f) => !["Row_Type__c", "Source_Branch_Name__c", "Credited_Advisor__c", "Code_Follow_Up__c"].includes(f.api)).forEach((f) => add(fieldBlock(f)));
add(H3("Import Batch: matching roll-ups"));
live.Import_Batch__c.forEach((f) => add(fieldBlock(f)));
add(H2("12.5 Sample files and expected outcomes"));
add(...table(["Firm", "Rows", "Matched", "Review", "Held", "Invalid", "What the held and review rows show"], [
  ["BARDER", "10", "5", "1", "3", "1", "Priya Nair on Marcus Bell's code 2210 (silent reassignment, 2 rows); unknown code 3390; unseen fund name"],
  ["NORTHGATE", "11", "5", "0", "4", "2", "Team code 8800 at 80% with no name (trade and AUM row); ended code 3102; dormant code 5521 with no name"],
  ["LUMIERE", "5", "5", "0", "0", "0", "Accents, one advisor named on a team code, both named, neither named"],
  ["KESTREL", "2", "-", "-", "-", "-", "Mapping Review (no profile; planted)"],
], [1200, 700, 900, 800, 700, 800, 4260]));
add(...table(["Follow-up", "Reason", "Held rows", "Held trade value"], [
  ["BARDER 2210", "Reassignment Suspected", "2", "$280,000"],
  ["BARDER 3390", "Unknown Code", "1", "$45,000"],
  ["NORTHGATE 8800", "Allocation Incomplete", "2", "$1,200,000 (the AUM row is counted but not valued)"],
  ["NORTHGATE 3102", "Code Ended", "1", "$55,000"],
  ["NORTHGATE 5521", "Code Dormant", "1", "$18,000"],
], [2200, 2500, 1300, 3360]));
add(P("Resolution scenario: Barder confirms Priya Nair took over 2210 on 2026-09-15. Ending Marcus Bell's assignment, adding Priya at 100% and resolving the follow-up re-matches both rows to her."));
add(H2("12.6 Verification report"));
add(...table(["Check", "Result"], [
  ["Syntax", "22 classes, 2 triggers and 4 anonymous scripts parse (negative control: a broken statement is caught)"],
  ["Static analysis", "0 findings in PMD security, performance and error-prone categories"],
  ["Logic cross-check", "115 shared vectors pass in the Python port (85 from phase 2 plus 18 name-compatibility, 6 accent-folding and 6 similarity cases). The Python simulation of all 29 sample rows, 5 follow-ups and the resolution scenario matches the design intent; the same expectations are generated into DemoScenarioTest. Simulation world confirmed identical to the phase 1 seed data in the org"],
  ["Metadata consistency", "0 problems across 28 code files and 80 fields on 10 objects. Negative controls: a misspelled field in a subquery, a child relationship on the wrong parent, and a field on the wrong object in a constructor are all caught"],
  ["Apex runtime lint", "0 problems in 28 files (null assert messages, isBlank on delimiters, byte order marks)"],
  ["Permissions", "Every non-required custom field on the import objects has field permissions in both permission sets; the integration set covers every object matching reads"],
  ["XML", "146 metadata files well-formed"],
  ["Push job tests", "11 of 11 pass"],
  ["Org gate, run 1", "Run from the Zip project folder by mistake (12 unrelated files, API v59.0); nothing deployed. Rerun with the absolute force-app path"],
  ["Org gate, run 2", "All 146 components compiled; 60 of 66 tests passed. 6 failures from one bug (see 12.7): matching's user-mode update was rejected. CodeFollowUpService (40%) and its trigger (0%) were below 75% only because those tests stopped early. Every other class 83-100%"],
  ["Org gate, run 3", "Passed: 66 of 66 tests, 146 components. Coverage: TradeMatcher 99%, CodeFollowUpService 96%, CodeFollowUpTrigger 100%, every other class 83-100%. DemoScenarioTest confirmed every sample row, all 5 follow-ups and the resolve, reopen and close flows on the platform"],
  ["End-to-end run", "Deployed; push job sent the 4 sample files through staging and matching as two background jobs. Results matched the expected tables exactly: BARDER 10 rows (5 matched, 1 review, 3 held, 1 invalid); NORTHGATE 11 (5, 0, 4, 2); LUMIERE 5 matched; KESTREL Mapping Review; 5 follow-ups with the expected row counts and held values ($280,000, $45,000, $1,200,000, $55,000, $18,000)"],
  ["Resolution demo", "demo-resolve-2210.apex ended Marcus Bell's share on 2026-09-14, added Priya Nair at 100% from 2026-09-15 and resolved the follow-up. The trigger released the 2 held rows and queued re-matching: rows 4 and 5 came back Matched, credited to Priya Nair; Marcus Bell's own 2026-09-08 trade stayed credited to him; follow-up Resolved with 0 held rows and $0. Loop closed with no manual row edits"],
], [2400, 6960]));
add(H2("12.7 Issues found before delivery"));
add(...table(["Found by", "Issue", "Fix"], [
  ["Syntax check", "merge and where are reserved words in Apex (a method named merge, a variable named where)", "Renamed to combine and context"],
  ["Static analysis", "Inner class without a sharing declaration (ApexSharingViolations)", "Declared with sharing"],
  ["Manual review", "COUNT() aggregate read without a cast; helper method parameters shadowing fields; Integer compared to Decimal in a test", "Explicit Integer cast; renamed parameters; decimal comparison"],
  ["Negative control", "The cross-reference checker did not know child relationship names (flagged the valid Assignments__r subquery) and its constructor pattern ran past a closing parenthesis into the next statement", "Checker now reads relationship names from metadata, validates subqueries against the child object and matches parentheses; proven with three planted mistakes"],
  ["Blind-spot review", "Matching runs as the integration user in user mode, but that permission set could not read Accounts, Contacts or Products", "Read access added; invisible today because the demo pushes as the admin"],
  ["Guide review", "The run guide referred to a Code Follow-Ups tab that did not exist, and gave roster flags that are only true before the reassignment is resolved", "Tab added (visible through the admin permission set); guide shows the roster before and after"],
  ["Org gate", "Matching updated the rows it had queried with 'update as user'. User-mode DML checks edit access on every populated field, and the query included the batch master-detail, which can never be edited, so the whole update was rejected ('fields being inaccessible'). The follow-up resolution code had the same pattern. Local checks could not see it: it is a platform rule, and phase 2 only inserted rows", "Both now update fresh records holding only the fields they change. The cross-reference checker now flags user-mode updates of queried records that include master-detail, formula, roll-up or auto-number fields; proven on the original code"],
  ["First run", "PowerShell refused reset-demo.ps1: scripts extracted from a downloaded zip carry an internet mark, and the execution policy blocks unsigned ones", "Unblock-File on that one script (no change to the machine's execution policy); added to the run guide"],
  ["Script review", "The demo resolution would hit the 100% active-allocation rule if the new share were added before ending the old one", "Script ends Marcus Bell's share first; it is safe to re-run"],
], [1800, 4100, 3460]));
add(H2("12.8 Runbook"));
add(...CODE([
  "sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests <11 test classes>",
  "sf project deploy start --source-dir force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests <11 test classes>",
  "sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo",
  "sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo",
  ".\\scripts\\reset-demo.ps1   then   python push_job.py --lake ..\\datalake --once --auth sfcli --target-org tradeDemo",
  "sf apex run --file scripts/apex/demo-resolve-2210.apex --target-org tradeDemo",
]));
add(H2("12.9 Known limitations (by design for 3A)"));
add(B("A trade naming several members of a team code splits by the whole team's percentages, not just among those named (see open questions)."));
add(B("Reassignment is detected from the advisor name only. The previous-holder-resurfaces and branch-shift signals come later."));
add(B("Dormancy threshold is one constant (180 days) for every firm."));
add(B("Roster rows are classified but not yet applied; approval that creates codes and assignments arrives in 3B."));

add(H1("13. Phase 3B build record (2026-10-14)"));
add(H2("13.1 What it does"));
add(P("Claude now works on what the rules could not settle. After every matching run, Claude looks at rows in Needs Review and open Code Follow-Ups. For each one it suggests a firm, fund or advisor, with a confidence (High, Medium, Low) and a short explanation that cites the evidence. For a roster row it also recommends approve, reject or unsure. A reviewer accepts or rejects. **Claude suggests; a person decides.**"));
add(P("Three new review actions close the loop. **Accept** on a trade row applies the suggested (or reviewer-chosen) firm or fund and re-matches the row; with Remember Choice, the spelling becomes an alias so the next file matches by itself. **Accept** on a roster row sets up the advisor, code and assignment, ends the old holder's share and resolves the matching follow-up, which releases its held trades. **Activating** a Claude-proposed mapping profile processes the file that was waiting for it."));
add(P("Reviewers can also teach plain-language **Matching Rules** per firm. Active rules are sent to Claude with every request, and a rule must be activated by someone other than its author."));
add(H2("13.2 How it works"));
add(...table(["Step", "What happens", "Where"], [
  ["1. Queue", "TradeMatcher queues ClaudeSuggestionJob after each run; ImportBatchProcessor queues MappingProposalJob when no profile matches a file", "Queueables with AllowsCallouts"],
  ["2. Build the request", "Up to 10 items per request (setting). Firms, funds and the relevant advisors (with their codes, shares and dates), active matching rules and, for follow-ups, the held rows and any roster rows for that code. Records are sent under short keys (F1, P2, A3), never Salesforce Ids", "ClaudeSuggestionService.buildRequest"],
  ["3. Call Claude", "Models API (aiplatform.ModelsAPI.createGenerations), so the request passes through the Einstein Trust Layer. Model name from custom metadata. All callouts happen before any DML in the job", "ClaudeService"],
  ["4. Validate", "The answer must be JSON. Each entry must name an item that was sent, every key must be one of that item's candidates, confidence must be High, Medium or Low, and an explanation is required. Fields that were not asked for are ignored. Anything else is discarded and listed in the log", "ClaudeSuggestionService.validate (pure, mirrored in Python)"],
  ["5. Record", "One AI Request Log per call (prompt, raw response, model, duration, status, problems). Each item gets AI Status: Suggested, No Suggestion, Invalid or Failed. Items are asked once; clearing AI Status asks again", "ClaudeSuggestionJob"],
  ["6. Decide", "Reviewer Decision on the row. A before-update trigger validates it and stamps who decided and when; the after-update step teaches aliases, applies roster rows and re-queues matching", "ReviewDecisionService, RosterApprovalService"],
], [1500, 5360, 2500]));
add(P("Prompt safety: file contents and record data are sent as JSON under headings that say they are data, not instructions. Because Claude can only answer with keys it was offered, a malicious or garbled firm name in a file cannot make the system match to anything outside the candidate list."));
add(H2("13.3 Delivered"));
add(B("Objects: AI Request Log and Matching Rule (with layouts, list views and tabs), custom metadata type Trade AI Setting with a Default record. New tabs for Import Batches, Import Staging Rows (with a Needs Review list view) and Mapping Profiles. Totals: 12 objects, 114 fields, 10 validation rules."));
add(B("Apex: AiSettings, ClaudeClient (interface), ClaudeService, ClaudeSuggestionService, ClaudeSuggestionJob, MappingProposalService, MappingProposalJob, MappingActivationService, ReviewDecisionService, RosterApprovalService, MatchingRuleService. Triggers on Import Staging Row, Mapping Profile and Matching Rule. TradeMatcher honours Firm and Fund Overrides and resets a row's review state when it returns to Needs Review; ImportBatchProcessor saves the layout fingerprint and queues a proposal; reopening a follow-up clears its stale suggestion."));
add(B("Tests: 8 new test classes (19 in all) and two test utilities (a fake Claude that records prompts, and a small reference world shaped like the seed). Tests never call Claude."));
add(B("Scripts: reset-imports also clears AI logs and Claude-proposed profiles; request-suggestions re-asks Claude about failed or invalid items."));
add(B("Permissions: the integration permission set can create AI Request Logs and Draft mapping profiles, read Matching Rules and the AI setting; the admin set gets the new objects and tabs."));
add(H2("13.4 Field definitions (generated from the built metadata)"));
for (const [obj, title] of [["Import_Staging_Row__c@3B", "Import Staging Row: Claude suggestion and reviewer decision"], ["Code_Follow_Up__c@3B", "Code Follow-Up: Claude suggestion"], ["Import_Batch__c@3B", "Import Batch"], ["Mapping_Profile__c@3B", "Mapping Profile: Claude proposal"], ["AI_Request_Log__c@3B", "AI Request Log (AI_Request_Log__c), new object, record name AIR-{00000}"], ["Matching_Rule__c@3B", "Matching Rule (Matching_Rule__c), new object"], ["Trade_AI_Setting__mdt@3B", "Trade AI Setting (Trade_AI_Setting__mdt), custom metadata type"]]) {
  add(H3(title));
  live[obj].forEach((f) => add(fieldBlock(f)));
}
add(P("Also changed: Match Status gains the value Rejected; Match Method's description now covers Claude and Reviewer."));
add(H2("13.5 Demo scenario"));
add(...table(["Item", "Before", "Claude's role", "After the reviewer acts"], [
  ["Kestrel file (unknown layout)", "Mapping Review", "Proposes the column mapping, date format and buy/sell convention; saved as a Draft with its reasoning and the file checks", "Profile set to Active: file processed automatically"],
  ["Kestrel rows: \"Kestrel Capital\"", "Needs Review, FIRM_AMBIGUOUS (two firms share the name and code 1001)", "Tells the firms apart by advisor: Ryan Chen at Inc. (Calgary), Megan Chen at Ltd. (Vancouver)", "Accepted: matched and credited, Match Method Claude"],
  ["Barder row 6: \"ETF Wealth World Fund A\"", "Needs Review, FUND_UNRESOLVED", "Should flag that it could be the ETF or Series A rather than guess", "Reviewer picks the fund with Remember Choice: matched, alias taught"],
  ["Roster: Hannah Pierce on 3390", "Needs Review, NEW_ADVISOR, ROSTER_NEW_CODE", "Recommends approving", "Accepted: advisor, code and assignment created; 3390 follow-up resolved; Barder row 9 matched to her"],
  ["Follow-up 3390", "Open, Unknown Code", "Cites the roster row listing Hannah Pierce from 2026-09-20", "Resolved by the roster approval"],
], [2000, 2100, 2860, 2400]));
add(P("Verified in simulation: with the proposed mapping the Kestrel file stages cleanly, both rows are FIRM_AMBIGUOUS, and with the firms accepted they match to Ryan Chen and Megan Chen. A reviewer choosing a different firm than Claude is recorded as FIRM_FROM_REVIEWER, and a wrong choice is caught by the code check (held, not loaded)."));
add(H2("13.6 Verification report"));
add(...table(["Check", "Result"], [
  ["Syntax", "43 classes, 5 triggers and 5 anonymous scripts parse"],
  ["Static analysis", "0 findings in PMD security, performance and error-prone categories. Two findings fixed or justified: a debug statement removed; the one-job-per-waiting-file loop in MappingActivationService kept and suppressed with its reason (bounded at 20, checks the queue limit each pass)"],
  ["Logic cross-check", "31 Claude-response vectors (16 suggestion answers, 5 unparseable texts, 10 mapping proposals) pass in the Python port, with 18 expectations verified by hand rather than by the port; the same vectors are compiled into ClaudeValidationVectorTest. Kestrel end-to-end simulation matches the design. 3A scenario and 115 earlier vectors still pass"],
  ["Metadata consistency", "0 problems across 53 code files and 118 fields on 13 objects (including the custom metadata type)"],
  ["Apex runtime lint", "0 problems in 53 files after fixing 13 nullable Assert messages in the new tests (the phase 2 failure class); negative control proves the lint still catches them next to generic types"],
  ["Permissions", "Every new field has field permissions in both sets where its object is granted; the integration set covers everything the background jobs write"],
  ["XML", "219 metadata files well-formed"],
  ["Push job tests", "11 of 11 pass"],
  ["Org gate, run 1", "194 of 223 components deployed; 29 failures from three causes (see 13.7). Every class not depending on ClaudeSuggestionService compiled, including the Models API call in ClaudeService"],
  ["Org gate, run 2", "Passed: 223 of 223 components, 108 of 108 tests. Coverage: ClaudeSuggestionService 98%, ClaudeSuggestionJob 93%, MappingProposalJob 90%, ReviewDecisionService 91%, RosterApprovalService 91%, ClaudeService 81% (the uncovered lines are exactly the Models API call, which tests never make), all others 90-100%"],
], [2400, 6960]));
add(H2("13.7 Issues found before delivery"));
add(...table(["Found by", "Issue", "Fix"], [
  ["Simulation", "I assumed both Kestrel advisors' assignments had ended; the seed's second date is the last confirmed trade date, not an end date", "Expectations corrected: with the firm settled, both rows match. A cleaner demo story"],
  ["Runtime lint", "13 Assert messages in the new tests could be null, which fails on the platform even when the assertion passes", "Every message now contains a literal"],
  ["Runtime lint (false positive)", "A comma inside Map<String, String> was read as an argument separator", "The lint now skips generic type arguments; a planted control still fails"],
  ["Static analysis", "Debug statement in the suggestion job; enqueue inside a loop in the activation service", "Debug removed; loop kept with a written justification"],
  ["Manual review", "A reopened follow-up kept Claude's old suggestion, so new evidence would never be looked at", "Reopening clears the AI fields so Claude is asked again"],
  ["Manual review", "An inner class named Request shadowed the standard System.Request class", "Renamed SuggestionRequest"],
  ["Manual review", "A conditional expression mixed SObject and Code_Follow_Up__c branch types", "Both branches cast to SObject"],
  ["Manual review", "A rule could be edited after activation, bypassing the second approver", "Active rules cannot be edited; retiring clears the approval"],
  ["Manual review", "Custom metadata fields cannot be assigned in Apex, so the settings test as first written would not compile", "Test records are built from JSON"],
  ["Design review", "No UI path to staging rows and batches for reviewers before the phase 4 screen", "Tabs and a Needs Review list view added"],
  ["Org gate", "A variable named list_ does not compile: Apex identifiers cannot end with an underscore. The syntax parser used locally accepts it, and every class depending on ClaudeSuggestionService failed with it", "Renamed. The runtime lint now rejects identifiers with a trailing or double underscore (custom suffixes excepted); proven on the original code and a planted control"],
  ["Org gate", "CreatedDate cannot be placed on a page layout (it appears in the system section automatically)", "Removed from the AI Request Log layout. The cross-reference checker now rejects CreatedDate, LastModifiedDate, SystemModstamp and Id on layouts"],
  ["Org gate", "Permission set description over the 255-character limit", "Shortened. The checker now enforces the platform's length limits on descriptions, help text, labels, picklist values and validation messages"],
], [1800, 4100, 3460]));
add(H2("13.8 First live run (2026-10-15)"));
add(P("Deployed (108 of 108 tests). The first live calls succeeded: the Kestrel mapping proposal in 5.0 seconds and the first row suggestions in 5.8 seconds, all passing validation. Review of Claude's actual answers:"));
add(...table(["Item", "Claude's answer", "Assessment"], [
  ["Roster: Hannah Pierce on 3390", "Approve, High; cites the matching follow-up and roster date", "Excellent"],
  ["Follow-up 3390", "Advisor blank (not in Salesforce yet); approve the roster row first", "Excellent: declined to guess, gave the right sequence"],
  ["Follow-up 8800", "Low; active shares 50% + 30%, a 20% share ended; confirm the split with the dealer", "Excellent: found the planted trap"],
  ["Barder row 6 fund", "Series A, Medium, confirm the ETF prefix", "Acceptable answer, but cited the advisor's code as evidence for a fund"],
  ["Follow-up 3102", "Low, advisor blank, confirm with dealer", "Safe answer, wrong reasoning: it read 3102 as a Barder code because the prompt did not say which firm issued each code"],
  ["Follow-up 5521", "Tom Reilly, High", "Overconfident for a dormant code with no name on the row"],
], [2200, 3600, 3560]));
add(P("Explanations also mentioned internal keys (U3, R1, A6). Prompt tightened (3B.1): explanations must use names; each advisor's codes now carry the issuing firm; fund answers must rest on fund names and aliases only; a dormant code is rated High only with corroborating evidence. The validator needed no change: every key Claude used was a genuine candidate."));
add(P("Design gap found: resolving a Code Dormant follow-up without new data re-holds its rows, because dormancy is recalculated. Phase 4 adds a 'confirm holder' action on follow-ups (accepting Claude's suggested advisor records a confirmed trade date, which clears the dormancy)."));
add(H3("Second live run, after 3B.1 (2026-10-19)"));
add(P("3B.1 deployed (108 of 108 tests). The demo was reset and the roster and trade files pushed again: four requests, all Success (mapping proposal 4.8 s; row suggestions 2.8 s, 7.0 s and 17.2 s)."));
add(...table(["Item", "Claude's answer", "Assessment"], [
  ["Follow-up 3102", "Julia Morales's old Northgate code, ended 2024-05-28; she moved to Barder on 457. Low", "Fixed by 3B.1: correct reasoning"],
  ["Follow-up 5521", "Tom Reilly, Medium, capped for lack of corroboration", "Fixed by 3B.1"],
  ["Barder row 6 fund", "Series A, Medium, reasoning from fund names only", "Fixed by 3B.1, but the explanation still contained keys (P3, P5)"],
  ["Follow-up 3390", "Finds the roster row for Hannah Pierce; advisor blank", "Good"],
  ["Follow-up 8800", "Shares only reach 80%; cannot choose between the two holders", "Good"],
  ["Roster: Hannah Pierce on 3390", "Unsure, Low: verify with the dealer", "Wrong: the roster file is the dealer's own record. The prompt never said so, so the answer varied between runs"],
], [2200, 3600, 3560]));
add(P("3B.2 makes both fixes structural rather than hoping the model complies. (1) Prompt rule: roster rows are the dealer's authoritative record; recommend approve for a new advisor on a new code at a known branch unless the data conflicts, and never ask to confirm a roster row with the dealer. (2) ClaudeSuggestionService.readable(): before an explanation is saved, bracketed keys after a name are removed and any other key that was sent is replaced by its name (rows by record name, follow-ups as 'the 3390 follow-up'). Unknown keys and any key that is also a rep code in the request are left untouched, so a code such as A12 is never renamed. Mirrored in the Python port with 15 hand-written vectors (negative control: disabling bracket removal fails 6 of them), compiled into ClaudeValidationVectorTest.explanationsNeverShowKeys; ClaudeSuggestionTest covers the end-to-end path and the rep-code guard. 110 tests."));
add(P("3B.2 deployed (110 of 110 tests). Third run, 2026-10-19: Hannah Pierce's roster row Approve, High; no explanation contained a key; every request Success. One new issue: two trade files finished matching at the same moment and two suggestion jobs both asked about the same four follow-ups (AIR-00012 and AIR-00013), wasting one request. Phase 4 adds a guard so a job leaves the work to one already queued or running."));
add(P("Reviewer decisions, 2026-10-21, all through the record pages: Kestrel's Claude-proposed mapping activated and the waiting file processed automatically; both Kestrel rows accepted (Matched, method Claude, credited to Ryan Chen and Megan Chen); Barder row 6 accepted with Remember Choice (Matched, method Claude; new fund alias 'ETF Wealth World Fund A'); Hannah Pierce's roster row accepted, which created her contact at Oakville and code 3390, resolved the 3390 follow-up and re-matched Barder row 9 to her (method Exact). Phase 3B verified end to end."));
add(H2("13.9 Runbook"));
add(...CODE([
  "sf project deploy start --source-dir C:\\dev\\trade-import-demo\\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests <19 test classes>",
  "sf project deploy start --source-dir C:\\dev\\trade-import-demo\\force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests <19 test classes>",
  "sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo",
  ".\\scripts\\reset-demo.ps1 -Roster; push; wait 30 s; .\\scripts\\reset-demo.ps1; push",
  "Review: Mapping Profiles (activate Kestrel draft), Import Staging Rows > Needs Review (Reviewer Decision), AI Request Logs",
]));
add(H2("13.10 Known limitations"));
add(B("Each request carries the org's firms and funds; a large org would send only each item's candidates."));
add(B("Developer Edition chains at most five background jobs; anything left unasked keeps a blank AI Status and request-suggestions.apex picks it up."));
add(B("A roster row on a team code is refused (it names one advisor and cannot say how the split should change)."));
add(B("A dedicated integration user would also need the org's generative AI permission to call the Models API; the demo pushes as the admin."));

add(H1("14. Decisions log"));
add(...table(["Date", "Decision", "Reason"], [
  ["2026-10-06", "Claude adjudicates ambiguity only; deterministic tiers first", "Cost, repeatability and auditability"],
  ["2026-10-06", "LWC in Salesforce, Claude via Models API", "Demoable in-platform; Trust Layer for regulated data"],
  ["2026-10-06", "Automated push ingestion instead of manual upload only", "Mirrors the real data lake process"],
  ["2026-10-06", "Reviewer-taught Matching Rules with two-person approval", "System improves with use, safely"],
  ["2026-10-06", "Reassignment inferred from signals, not effective dates alone", "Firms never announce code transfers"],
  ["2026-10-06", "Shared codes via assignment % with snapshotted allocations", "Team splits change; history must not"],
  ["2026-10-12", "AUM defined as cumulative net sales from transactions", "Files contain dollar trades only, no units or prices"],
  ["2026-10-12", "Build as an SFDX project deployed by CLI to a Developer Edition org", "Repeatable, versionable, publishable"],
  ["2026-10-12", "Mapping Profile as a custom object", "Profiles are created at runtime by reviewers"],
  ["2026-10-12", "Every delivery passes six local checks plus an org dry run with tests", "Nothing is deployed on trust"],
  ["2026-10-12", "New batch status Staged between Received and matching", "Separates ingestion from matching so each can be rerun independently"],
  ["2026-10-12", "Decimal Separator on the profile; delimiter auto-detected", "French-language exports use decimal commas and semicolons"],
  ["2026-10-12", "Firm lookup on Mapping Profile for single-firm feeds", "Fills missing firm names with a real Account, not a code"],
  ["2026-10-12", "User-mode queries and DML throughout; separate integration permission set", "Least privilege for the push job, enforced by the platform"],
  ["2026-10-12", "Push job supports CLI login (demo) and JWT (production)", "Demo works immediately; production story is intact"],
  ["2026-10-12", "1 MB and 5,000-row limits per file", "Heap and CPU headroom; matches weekly volume"],
  ["2026-10-13", "AUM ingested from the feed as dated snapshots per rep code; replaces the net-sales assumption", "Confirmed: files mix trades and AUM per rep code in every file"],
  ["2026-10-13", "Mixed files split by a profile-configured AUM indicator", "Each dealer marks AUM rows differently"],
  ["2026-10-13", "Advisor code roster files ingested as their own feed type", "Dealers send codes in separate files; this is the missing intake that caused orphans"],
  ["2026-10-13", "Code Follow-Up to-do list for unknown, ended and dormant codes; held rows auto-release on resolution", "Greg's requirement; prevents orphans instead of reporting them"],
  ["2026-10-13", "Trade naming one member of a team code: 100% to that advisor", "Confirmed business rule"],
  ["2026-10-14", "Deterministic matching ships first (3A); Claude only sees what rules cannot settle (3B)", "Testable baseline; Claude's value is clearer against it"],
  ["2026-10-14", "Four outcomes per row: Matched, Needs Review, Held, Invalid", "Held separates 'missing code information' (a to-do) from 'a person must choose' (review)"],
  ["2026-10-14", "One follow-up per source firm, code and reason, keyed and upserted", "Repeat files add to the existing to-do instead of duplicating it"],
  ["2026-10-14", "A named advisor who holds none of the code's active shares holds the row as Reassignment Suspected", "Silent transfers are detected from the data, never assumed"],
  ["2026-10-14", "Fuzzy names accepted automatically only at 0.9 similarity or better with a 0.1 lead over the next candidate", "Typos auto-resolve; near-ties go to a person"],
  ["2026-10-14", "Dormancy: 180 days without confirmed activity, measured from the row date", "Deterministic results; per-firm threshold deferred"],
  ["2026-10-14", "Integration user granted read on Account, Contact and Product2", "Matching runs as that user in user mode"],
  ["2026-10-14", "Claude only suggests; a reviewer accepts (Reviewer Decision)", "Regulated data; accountability stays with a person"],
  ["2026-10-14", "Claude sees short keys, never Salesforce Ids, and may only answer with keys it was offered", "Answers can be validated exactly; invented records are impossible to apply"],
  ["2026-10-14", "One AI Request Log per call with the full prompt and response", "Audit trail and prompt tuning"],
  ["2026-10-14", "Model, on/off switch, batch size and two-person rule in custom metadata", "Change behaviour without code"],
  ["2026-10-14", "Ambiguous spellings are never taught as aliases, only unresolved ones", "An ambiguous name must keep going to review"],
  ["2026-10-14", "Roster approval ends the old holder the day before the roster date, source Confirmed by Firm; team codes left to a person", "Matches how firms report changes; team splits need human judgement"],
  ["2026-10-14", "Claude-proposed mappings are saved as Draft; activation re-processes waiting files", "A person approves every new file layout"],
  ["2026-10-19", "Keys are removed from explanations in code (readable()), not only by prompt instruction", "The model did not always comply; reviewers must never see internal keys"],
  ["2026-10-19", "Roster rows are treated as the dealer's authoritative record in the prompt", "Without it Claude's recommendation varied between runs"],
  ["2026-10-21", "Two tiers sharing one core: Enterprise (Models API, Trust Layer) and Standard (Anthropic Messages API called from Apex with the firm's own key)", "Large firms have Einstein licences and strict compliance; smaller firms cannot justify the licence. Only the Claude call differs"],
  ["2026-10-21", "Models API is the default; Standard tier is opt-in and needs both the Provider setting and a Named/External Credential; every AI Request Log records its provider", "Enterprises can prove nothing goes to Anthropic directly; the switch is audited in Setup Audit Trail"],
  ["2026-10-21", "External pipeline (stage, clean and load outside Salesforce) deferred as a possible third option", "Only needed for very high volume (Batch API), files beyond Apex limits, or firms wanting no AI processing in Salesforce"],
  ["2026-10-21", "Guided Setup Assistant (LWC wizard) for first-time configuration: tier and key, connection test, permissions, reference data, first file and mapping, settings", "Firms configure the app without Setup or a developer; only Einstein enablement and on-premises agents stay outside"],
  ["2026-10-21", "Three data intake paths, all in the first version: manual upload in the app, scheduled pull from cloud storage (S3, Azure Blob, Google Cloud Storage), and the push agent", "Small firms need zero infrastructure; enterprises keep their own integration; all three feed the same staging and matching pipeline"],
  ["2026-10-22", "Review app as a Lightning tab (Trade Review), with optional Assign to me", "Works for a single Salesforce champion or a team of insiders; the tab is the strongest view for the demo"],
  ["2026-10-22", "The app saves decisions to the same fields as the record page; all rules stay in the trigger and services", "One set of rules, refusals and audit stamps however a decision is made"],
  ["2026-10-22", "One intake service (FileIntakeService) for push, upload and cloud pull", "Every route gets the same duplicate check, size limit and pipeline"],
  ["2026-10-22", "Separate Trade Import Reviewer permission set, proven by a test that runs as a reviewer with nothing else", "Reviewers start background work that runs as them, so their access must be complete but no wider"],
  ["2026-10-22", "Phase 4b.1: Claude answers per field (suggestion, confidence and reason for each), shown as a table in the app and on the record page; token counts logged on every request; prompt caching on the Standard tier", "Reviewers see where Claude is sure and where it is not; cost is measured, not estimated (expected +5-15% per request before caching)"],
  ["2026-10-23", "Review feedback batch (4b.2): root-cause headlines (rule-based, replaced by Claude's once it answers); 'Why it needs review' shows each specific note once; a fourth decision, Put on hold, with homework text and an On Hold tab; roster rows show what approving will create; label spacing fixed", "First hands-on review: titles must say what is wrong, items that need the firm's answer must be parked, not forced to Accept or Reject"],
  ["2026-10-23", "Send follow-up to the firm: one email per firm combining its on-hold and code review questions, drafted by Claude, opened in the standard Send Email window for a person to edit and send, logged on the firm Account; items marked as asked. One Operations Contact per firm (lookup on Account); amounts left out by default", "Closes the loop with the dealer while keeping a person responsible for every message that leaves the firm"],
], [1300, 4400, 3660]));

add(H1("15. Open questions"));
add(B("Is AUM ever broken down by fund, or only a total per rep code? The design supports both (Fund is optional on the snapshot)."));
add(B("When a trade row names two or more members of a team code, should it split across just those members (by their relative percentages) or across the whole team? 3A splits by the whole team's percentages (identical for the two-person Lumière team); to be confirmed."));
add(B("Who works the Code Follow-Up list, and should it notify them, or is a list view enough?"));
add(B("Resolved 2026-10-13: Claude Sonnet 5, Sonnet 4.6 and Haiku 4.5 are available through the Models API; 3B uses Sonnet 5 with the model name in a setting. Still open: is Trust Layer data masking enabled for names?"));
add(B("Should the dormancy threshold vary by firm (currently 180 days for all)?"));
add(B("Should a High-confidence Claude suggestion ever be applied without a reviewer (for example firm disambiguation by advisor), or must a person always accept?"));
add(B("Who should be allowed to activate matching rules, and should Retired rules be kept or deleted?"));
add(B("Should reviewers be able to edit a team's split directly from the review screen, or only accept the suggested proportional re-split?"));
add(B("Resolved 2026-10-13: a Source Branch Name field is added to staging rows (needed for code roster files and the branch-shift signal)."));

add(H1("16. Phase 4a build record: Standard tier (2026-10-21)"));
add(H2("16.1 What it does"));
add(P("The same app now runs at two price points. Enterprise tier: Claude through the Models API and the Einstein Trust Layer, for firms with Einstein generative AI licences and strict compliance mandates. Standard tier: Claude through the Anthropic Messages API with the firm's own API key, for smaller firms that cannot justify the licence. One setting chooses the route; the prompt, validation, key clean-up, logging, review decisions and roster approval are identical, because only the client behind the ClaudeClient interface changes."));
add(H2("16.2 How it works"));
add(B("AiSettings reads Provider from the Trade AI Setting. Anything other than exactly 'Anthropic API' means the Models API, so a blank or mistyped value always falls back to the compliant route."));
add(B("ClaudeService.clientFor() picks ModelsApiClient or AnthropicApiClient and records the provider and model on every AI Request Log."));
add(B("AnthropicApiClient posts to callout:Anthropic_API/v1/messages (anthropic-version 2023-06-01, max_tokens 8000, 60-second timeout; the suggestion job starts no new request after 60 seconds, so its callouts stay within Apex's 120-second limit). It joins the answer's text blocks, ignores other blocks, and reports API errors with their type and message, a cut-off answer (max_tokens), a refusal and a non-JSON body as failures rather than half-parsing them."));
add(B("The API key is held by the Anthropic_API external credential (Custom protocol, x-api-key header from {!$Credential.Anthropic_API.ApiKey}) and entered in Setup on the Anthropic principal. It is never in code, metadata, the repository or the logs; the code does not set the header itself, and a test proves it."));
add(H2("16.3 Compliance controls"));
add(...table(["Control", "Effect"], [
  ["Models API is the default", "A fresh install never sends data to Anthropic directly"],
  ["Provider must be exactly 'Anthropic API'", "Any other value stays on the Trust Layer route"],
  ["Credential and permission set are separate components", "An Enterprise org can leave out the external credential, named credential and the Trade Import Anthropic API permission set; no Apex depends on them at compile time"],
  ["Principal access only through Trade Import Anthropic API", "Without it the callout fails and the request is logged Failed; nothing is sent"],
  ["Provider on every AI Request Log", "Auditors can show which route each prompt took"],
  ["Setting is custom metadata", "Changes need admin rights, appear in Setup Audit Trail and move between orgs only by deployment"],
], [3600, 5760]));
add(H2("16.4 Delivered"));
add(B("Apex: AnthropicApiClient (new), AiSettings (provider, Anthropic model, activeModel()), ClaudeService (provider choice, Provider on the log), ClaudeClient (comment). Tests: AnthropicApiClientTest (new, with a reusable HTTP mock), AiSettingsTest and ClaudeServiceTest extended."));
add(B("Metadata: Trade AI Setting fields Provider (default Models API) and Anthropic Model (claude-sonnet-5-5); AI Request Log field Provider (layout and list view); external credential and named credential Anthropic_API; permission set Trade Import Anthropic API (principal access, read on User External Credential)."));
add(H2("16.5 Field definitions (generated from the built metadata)"));
["AI_Request_Log__c@4A", "Trade_AI_Setting__mdt@4A"].forEach((obj) => {
  add(H3(obj.startsWith("AI") ? "AI Request Log" : "Trade AI Setting (custom metadata type)"));
  live[obj].forEach((f) => add(fieldBlock(f)));
});
add(H2("16.6 Verification"));
add(B("Parse, PMD security, performance and error-prone rules (zero findings; negative control: an empty catch block is flagged), runtime lint (negative control: a null assert message is flagged), metadata cross-reference (121 fields; negative control: a misspelt metadata field is flagged)."));
add(B("The response handling is tested directly against hand-written Anthropic response bodies: text joining, thinking blocks ignored, 401 with an error body, plain-text 529, empty and null bodies, max_tokens, refusal, non-JSON and non-object JSON, malformed blocks. The end-to-end path is tested through an HTTP mock, including a missing credential (logged Failed)."));
add(H2("16.7 Known limitations"));
add(B("Redeploying the project resets the Default setting record to Models API; switch Provider again after a deploy."));
add(B("The external credential and named credential XML are first validated by the org dry run; there is no local schema check for them."));
add(B("The Standard tier sends data to Anthropic directly. It suits firms whose compliance approves that path, ideally with a zero data retention agreement; Trust Layer masking does not apply."));

add(H1("17. Phase 4b build record: Trade Review app (2026-10-22)"));
add(H2("17.1 What it does"));
add(P("One Lightning tab, Trade Review, replaces working from record pages. Reviewers see everything waiting for a person in one queue (rows in Needs Review grouped by file, open code follow-ups, files whose layout needs a mapping, and recent files), with Claude's suggestion and the evidence next to each item. They accept Claude's choice, pick their own, tick 'remember this spelling', reject, approve roster rows, activate Claude's proposed mappings and upload dealer files, all without leaving the page. The page refreshes itself while background work (staging, matching, Claude) is running."));
add(P("Built for both ways firms work: a single Salesforce champion can ignore assignment entirely, and a team can use Assign to me so two people never work the same item (Mine and Unassigned filters)."));
add(H2("17.2 How it works"));
add(B("The app decides nothing itself. ReviewController saves the decision and overrides to the staging row exactly as the record page does, so StagingRowTrigger, ReviewDecisionService and RosterApprovalService apply the same rules, refusals and audit stamps; their messages are shown to the reviewer as they are."));
add(B("FileIntakeService is now the single intake for every route a file can take: the REST endpoint used by the push job (refactored onto it, behaviour unchanged), the app's upload, and phase 4c's cloud-storage pull. Same SHA-256 duplicate check, same 1 MB limit, same pipeline."));
add(B("Assignment: Assign to me succeeds only when the item is unassigned (or already yours); only the assignee can unassign. The row is locked (FOR UPDATE) while checking, so two people clicking at once cannot both take it. Admins can still change the field on the record page."));
add(B("Background progress: the queue reports how many files, rows and Claude requests are still being worked on; the page refreshes every 5 seconds while that is above zero, for up to 3 minutes after the last action, then asks the reviewer to refresh. If Claude's suggestion arrives while a row is open, its choices are filled in unless the reviewer has already chosen."));
add(B("Every query and update runs in user mode, so reviewers see and change only what their permissions allow."));
add(H2("17.3 Permissions"));
add(P("New permission set Trade Import Reviewer for people who work the queue but are not admins. A reviewer's actions start background work that runs as the reviewer (staging an uploaded file, re-matching, applying roster rows, raising follow-ups, saving Claude's mapping proposals), so it grants the same data access as the integration user plus the roster writes: create Contact (with Account), Rep Code and Rep Code Assignment, and create aliases. Claude calls additionally need the org's generative AI permission (Enterprise tier) or Trade Import Anthropic API (Standard tier). A test runs every reviewer action as a Standard User holding only this permission set, which has no access of its own to the app's objects."));
add(H2("17.4 Delivered"));
add(B("Apex: ReviewController (queue, decideRow, setAssignment, activateMapping, uploadFile), FileIntakeService (new), TradeIngestResource (now delegates to FileIntakeService). Tests: ReviewControllerTest (14 tests, including the reviewer-only access test)."));
add(B("LWC: tradeReview (queue, detail, decision, follow-up, mapping and upload views; 17 Jest tests). Tab Trade Review (on the Admin and Reviewer permission sets)."));
add(B("Metadata: Assigned To on Import Staging Row and Code Follow-Up (on both layouts); permission set Trade Import Reviewer."));
add(H2("17.5 Field definitions (generated from the built metadata)"));
["Import_Staging_Row__c@4B", "Code_Follow_Up__c@4B"].forEach((obj) => {
  add(H3(obj.startsWith("Import") ? "Import Staging Row" : "Code Follow-Up"));
  live[obj].forEach((f) => add(fieldBlock(f)));
});
add(H2("17.6 Verification"));
add(B("Apex: parse, PMD security, performance and error-prone rules (zero findings), runtime lint, metadata cross-reference (123 fields). LWC: ESLint with the Salesforce LWC rules, Prettier, 17 Jest tests (negative control: sending no firm on Accept fails 2 of them)."));
add(B("New check, lwc_xref.py: every Apex method an LWC imports exists as @AuraEnabled and every call passes exactly its parameter names (Aura matches parameters by name, so a typo silently sends null). Negative control: renaming rememberChoice is caught."));
add(H2("17.7 Known limitations"));
add(B("The queue shows the first 200 rows and 100 follow-ups (the Rows tab shows 200+ when there are more); Mine and Unassigned narrow it."));
add(B("Follow-ups are resolved on their record page (Open follow-up to resolve); the Confirm holder action for dormant codes is phase 4e."));
add(B("Refreshing is polling while work is in flight, not push notifications; phase 4e adds notifications."));

add(H2("17.8 Phase 4b.1a: names, issue types and a full demo reset (2026-10-23)"));
add(B("Tabs renamed after first use: Needs Decision, Code Review, New File Format, Recent Files. Code Review is now a table with an Issue type column (and Claude's confidence); each held trade shows its own issue in the held trades table. Needs Decision says how many trades (and how much money) are held behind code reviews, with a link to that tab, so an empty decision list never looks like 'nothing to do'."));
add(B("Fix found by a new test: switching tabs kept the previous tab's item open. Selection is now limited to the open tab."));
add(B("FileIntakeServiceTest covers every refusal (firm code, file name, empty, too large, damaged in transit) and the duplicate path; coverage was exactly 75% before."));
add(B("Full demo reset (scripts/reset-demo-full.ps1): clears imports, then reset-reference-data.apex (generated from the seed files) deletes every rep code, assignment, alias, matching rule and any advisor at the seeded firms who is not in the seed, and recreates the seeded codes, assignments and aliases. Firms, branches, seeded advisors, funds and mapping profiles keep their Ids. It then pushes the roster, waits 30 seconds and pushes the trade files."));
add(P("The sample data now plants every problem the matcher can raise, each checked by the simulation and by DemoScenarioTest:"));
add(...table(["Where", "Problem planted", "Outcome"], [
  ["Barder row 11", "Trade dated before code 457 started", "Needs Decision: DATE_BEFORE_CODE_START"],
  ["Barder row 12", "'Wealth World Fund' (new seed trap: the spelling dealers use for both series)", "Needs Decision: FUND_AMBIGUOUS"],
  ["Northgate row 12", "Firm written as 'Northgate Securities Ltd'", "Needs Decision: FIRM_UNRESOLVED"],
  ["Lumiere row 6", "A trade on team code 7700 naming someone not on the team", "Code Review: Reassignment Suspected (TEAM_CHANGE_SUSPECTED)"],
  ["Kestrel row 3", "No firm name at all (multi-firm feed)", "Needs Decision after the mapping is activated: FIRM_MISSING"],
  ["barder_trades_2026-10-05_resent.csv", "The same Barder file sent again under another name", "Recognised by its contents; nothing loaded twice (push job reports DUPLICATE)"],
  ["northgate_trades_2026-10-06.csv", "File damaged in transit (unclosed quote)", "Batch Failed with the reason; nothing staged (Recent Files)"],
], [2400, 3800, 3160]));
add(P("Together with the existing rows the demo shows: firm ambiguous, unresolved and missing; fund unresolved and ambiguous; date before code start; roster new code with new advisor, roster new holder; all five code review issues (unknown, ended, dormant, reassignment and team change, allocation incomplete); invalid rows (missing amount, impossible date, unknown transaction type); fuzzy firm and fund names; team split and single-member credit; AUM rows; an unknown file format; a duplicate file; a damaged file. Not planted: an ambiguous advisor name on a roster row (the seed has no two advisors with confusable names at one firm)."));

add(H1("18. Phase 4b.2 build record: review feedback (2026-10-23)"));
add(H2("18.1 What changed for the reviewer"));
add(...table(["Feedback", "What the app does now"], [
  ["Titles said 'BARDER · row 2'", "Each item is titled by its root cause, naming the person, code, fund or firm: 'Priya Nair · Rep code mismatch on 2210'. Until Claude answers, the title is built from the match flags; Claude's own headline (up to 100 characters) replaces it when it arrives. The file and row move to a second line."],
  ["'Why it needs review' repeated itself", "Shows the matcher's specific notes, each once (duplicates removed); the generic flag wording is used only when a row has no notes."],
  ["Some rows only the dealer can settle", "A fourth decision, Put on hold, asks what needs to be found out (pre-filled with Claude's homework when it recommends Hold) and moves the row to a new On Hold tab. From there: Accept, Reject or Release back to Needs Decision. Any decision takes the row off hold. Claude can now recommend Accept, Reject or Hold."],
  ["Does approving a roster row create the records?", "Roster rows list exactly what approving will do before you click: create the advisor (and at which branch), create the code, end the previous holder's assignment (with the date), assign the code 100% from the roster date, and close the code review and re-match its held trades. Rows that cannot be approved say why and Approve is switched off (a missing firm can still be chosen first)."],
  ["'Firm:Northgate…' with no space", "Labels and values are separate elements with a margin; LWC drops whitespace between an element and an expression, which caused it."],
  ["Claude's answer as a table", "Claude answers per field: Field, Suggestion, Confidence, Reason. Shown in Trade Review and, through the new AI Suggestion Table component, on the Import Staging Row and Code Follow-Up record pages."],
  ["Contact the firm from the app", "A 'Waiting for the firm' strip lists every firm with questions (rows on hold plus open code reviews). Email the firm drafts one email for all of them, written by Claude when it is on (a numbered list otherwise), and opens it in Salesforce's standard Send Email window addressed to the firm's Operations Contact and related to the firm Account, so a person edits and sends it and it is logged on the Account. Afterwards the app offers to mark the questions as asked; each item then shows 'Asked Oct 20', and after 3 days without an answer, a reminder label. Amounts are never included."],
], [2600, 6760]));
add(H2("18.2 How it works"));
add(B("Answer format 2: each suggestion carries a headline, a list of field answers ({field, value, confidence, reason}, values by key, translated to record names before storing), an action (accept, reject, hold), homework (required for hold) and the overall explanation. Validation is strict and mirrored in Python with shared vectors: unknown fields, duplicate fields, values outside the item's choices and 'accept' without the firm and fund the row needs are rejected; text is length-capped and cleaned of internal keys."));
add(B("Token logging: every AI Request Log records input, output and cached input tokens, read from the provider's response (Models API usage block or Anthropic usage, including cache reads and writes)."));
add(B("Prompt caching (Standard tier): the instructions, which are the same on every request, are sent as a cached system block; only the items change. Anthropic bills cache reads at a fraction of the normal input rate. The Models API route sends the same text as one prompt."));
add(B("Firm follow-up email: ReviewController.draftFirmEmail gathers the firm's on-hold rows (by matched firm, or the mapping profile's firm for single-firm feeds) and open code reviews, builds one question per item without amounts, and asks Claude for a JSON {subject, body}. The call is logged with Purpose 'Firm Follow-up'; an unusable answer is logged Invalid and the standard list is used. The body is HTML-escaped before it reaches the email window. Nothing is sent by Apex."));
add(B("On hold is a flag on the staging row, not a new status, so matching, re-matching and every existing rule are unchanged; a row on hold that a later fix matches (for example an approved roster row) simply leaves the queue."));
add(H2("18.3 Delivered"));
add(B("Apex: ReviewController (holdRow, releaseHold, draftFirmEmail, markAsked; headlines, de-duplicated notes, field table, roster preview, firm follow-ups in the queue), RosterApprovalService.preview, ClaudeSuggestionService (answer format 2, headline, action, homework, field table), ClaudeService and both clients (token counts, cache marker), ReviewDecisionService (clears On Hold), TradeMatcher and CodeFollowUpService (clear the new Claude fields on re-match). Tests: 8 new in ReviewControllerTest (hold and release, hold refusals, one email per firm without amounts, Claude-drafted email logged and its fallback, missing contact, standard questions, roster preview, headlines and notes), plus cache and token tests in AnthropicApiClientTest and ClaudeServiceTest; validation vectors regenerated."));
add(B("LWC: tradeReview (On Hold tab, hold dialog, field table, recommended action, approval preview, firm follow-up strip and Send Email, asked and reminder labels; 30 Jest tests) and aiSuggestionTable (new, record pages; 5 Jest tests)."));
add(B("Metadata: 9 fields on Import Staging Row, 3 on Code Follow-Up, Operations Contact on Account, 3 token fields on AI Request Log and the 'Firm Follow-up' purpose; layouts and permission sets updated (Admin edits Operations Contact; Reviewer reads it and Contact Email)."));
add(H2("18.4 Field definitions (generated from the built metadata)"));
[["Import_Staging_Row__c@4B2", "Import Staging Row"], ["Code_Follow_Up__c@4B2", "Code Follow-Up"], ["Account@4B2", "Account"], ["AI_Request_Log__c@4B2", "AI Request Log"]].forEach(([obj, title]) => {
  add(H3(title));
  live[obj].forEach((f) => add(fieldBlock(f)));
});
add(H2("18.5 Verification"));
add(B("Apex: all files parse; PMD security, performance and error-prone rules (zero findings); runtime lint; metadata cross-reference (139 fields; negative control: a misspelt relationship on the new Account lookup is caught). 145 tests in 22 classes for the org dry run."));
add(B("LWC: ESLint, Prettier, 35 Jest tests (negative controls: pointing the email at another action and dropping the 'cannot approve' rule each fail tests; blanking the field name in the record-page table fails one). lwc_xref.py now also accepts shorthand parameters ({ firmId }) and checks every @salesforce/schema import exists in the package (negative controls: a wrong parameter name and a misspelt schema field are both caught)."));
add(B("First org dry run: one compile error. A test named a variable 'system', which is a reserved word in Apex (the parser used locally accepts it). Renamed, and apex_lint.py now flags any reserved word used as a variable or parameter name (negative control: the original file is caught)."));
add(B("Second dry run: one test failure in the test itself. Its pretend Claude reply wrote line breaks as '\\n' in Apex, which is a real line break and not valid inside a JSON string; the app correctly rejected the answer, logged it and fell back to the standard list. The test now writes JSON line breaks correctly. Third dry run: 145 of 145 passing."));
add(H2("18.6 Known limitations"));
add(B("The Send Email window opens from the app tab through the standard Global.SendEmail action; the To, Subject and Body fields must be editable on that action's layout (they are by default)."));
add(B("Asked dates are set when the reviewer confirms the email was sent; the app cannot see whether it was actually sent. Replies are read in the email thread on the Account; the app does not parse them."));
add(B("Add Operations Contact to the Account page layout by hand (standard object layouts are not part of this package)."));

add(H2("18.7 Phase 4b.2a: one table layout and code issues together (2026-10-25)"));
add(P("Feedback after using 4b.2: the firm email strip looked out of place above the tabs, and Needs Decision and Code Review looked like two different apps. Code Review's table read better, but Needs Decision's information had to stay."));
add(...table(["Change", "How"], [
  ["Tab order", "Dealer Code Review, Needs Decision, On Hold, Email Firms, New File Format, Recent Files. The app opens on Dealer Code Review."],
  ["One table everywhere", "A shared component (reviewQueueTable) draws every queue: Item (headline, file and row, assignment or asked date), Issue type (with '+N more', Claude's confidence and recommended action) and Amount or count, with group header lines. Each tab only supplies its own lines."],
  ["Code issues together", "ReviewController marks each row isCodeIssue when it is a roster row or carries any rep code flag (new holder, new code, advisor unclear, unknown, ended, before code start, dormant, reassignment, team change, allocation incomplete, review closed). Those rows join the codes to fix in Dealer Code Review; firm, fund and other data questions stay in Needs Decision, grouped by file. The rule lives in Apex so the app and its tests agree."],
  ["Issue type column", "A short type per row from the highest-priority flag (for example New code holder, Unknown fund), informational flags such as fuzzy matches excluded."],
  ["Email Firms tab", "One line per firm (contact, status, question count). The detail lists each question with where it came from and when it was asked, the Operations Contact (or how to set it), Email the firm, and the Mark as asked prompt for that firm only."],
], [2400, 6960]));
add(B("Verification: Apex parse, PMD (zero findings), lint, cross-reference; new test codeIssuesAreSeparatedFromOtherDecisions and firm question assertions (146 tests). LWC: 40 Jest tests including the new table component; negative controls: dropping the code-issue filter fails 4 tests, showing the Mark as asked prompt on every firm fails 1."));

add(H2("18.8 Phase 4b.3: rows that share an issue are decided together (2026-10-25)"));
add(P("Feedback: insiders work this queue, and a misspelt firm or fund usually repeats on many rows. They need to see how many rows an issue affects (to confirm it with the dealer) and to fix them in one step. Decisions: one line per issue, and one decision reaches every open row with that issue from the same dealer, in any file. Rows with both a code issue and another issue stay in Dealer Code Review only."));
add(...table(["Part", "How it works"], [
  ["Issue Key", "New field on Import Staging Row, set by TradeMatcher for rows waiting for review: the dealer, plus each firm or fund issue (FIRM_MISSING, FIRM_UNRESOLVED, FIRM_AMBIGUOUS, FUND_UNRESOLVED, FUND_AMBIGUOUS) with the normalised spelling. Missing and ambiguous names also include the rep code, because the right firm can differ by code. Blank for roster rows, code issues and rows not in review. Keys over 255 characters are stored as a SHA-256 hash. External ID so lookups by key are indexed."],
  ["Queue", "A light query picks one row to stand for each issue (and every row that shares none), then an aggregate query gives each issue's row count, total amount and file count. A large group cannot push other issues off the page."],
  ["Decisions", "decideRow, holdRow, releaseHold and Assign to me apply to every open row with the same key and on-hold state, all or none, and return how many rows changed. One chunk is at most 200 rows (one trigger chunk, so re-matching is queued once); the rest stay in the queue. Remember this spelling teaches the alias once."],
  ["Firm email", "Rows held for the same issue become one question that names the spelling and says how many rows and files it covers. Mark as asked stamps every row."],
  ["App", "Group lines show 'N rows · total' and 'dealer · N files'. The detail explains the reach, lists up to 50 of the rows (file and row, date, code, advisor, firm, fund, amount) through the new getIssueRows method, and the buttons say Accept all N, Reject all N, Put all N on hold, Release all N."],
], [1900, 7460]));
add(B("Why it matters: Remember this spelling already fixed future files, but re-matching only picks up Pending rows, so other rows with the same spelling already in review stayed there. Group decisions close that gap."));
add(B("Verification: 151 Apex tests (new: issue keys in TradeMatcherTest; one line with totals, one decision for all, chunking, holding and the single firm question in ReviewControllerTest). apex_lint.py gained a rule that SOQL with FOR UPDATE cannot use ORDER BY (it caught one in this build; negative control confirmed); the reserved-word rule caught a variable named group. 42 Jest tests in tradeReview (negative control: dropping the 'all N' labels fails one)."));
add(B("Not yet: Claude is still asked about each row of a group separately; asking once per issue and copying the answer would cut cost for large groups."));
add(H3("Field definition"));
live["Import_Staging_Row__c@4B3"].forEach((f) => add(fieldBlock(f)));

add(H1("19. Code audit and fixes, part 1 (2026-10-26)"));
add(P("An independent audit (a separate agent that had not seen the code being built) read every class, trigger and component and ran the local checks on a copy. Its verdict: the pipeline design, the Claude safety model and the tests are strong; the weaknesses are the security model of the background steps, concurrency around Claude, a few matching edge cases and accuracy in the public repository. The findings are in CODE_AUDIT.md in the Claude Project. Part 1 fixes the repository findings and the small correctness findings; the security model (F-01), Claude concurrency (F-02), per-issue Claude calls, prompt-cache layout (F-19), the stranded-work sweeper (F-08), CI (F-29) and the larger refactors follow."));
add(H2("19.1 Correctness fixes"));
add(...table(["Finding", "Fix"], [
  ["F-04 Team split credited people the name rules out", "When a row's name fits some members of a team code but not all (\"Chen\" on a team with Ryan Chen, Megan Chen and Julia Morales), the row goes to Dealer Code Review with ADVISOR_AMBIGUOUS and the members it fits as the choices. The reviewer's choice is stored in the new Advisor Override field; re-matching credits that member 100% (ADVISOR_FROM_REVIEWER). Claude is asked to choose among the same members."],
  ["F-05 Code reviews were grouped by dealer, not firm", "The follow-up key is now the matched firm's Id + code + reason, so a dealer file covering two firms (Kestrel Inc. and Ltd.) gives each firm its own code review, roster approval resolves the right one, and the email goes to the right firm. DemoScenarioTest now identifies follow-ups by firm, code and reason instead of by the key text."],
  ["F-06 Last Confirmed Trade Date was never written", "Each matched trade moves its credited assignments' date forward (all members for a team split). Written in system mode for that one field, because the integration user has no edit access to assignments."],
  ["F-07 One dealer's single-firm profile could fill in its firm on another dealer's file", "When the only Active profile for a layout is another dealer's single-firm profile, the file is treated as a new layout for its own dealer (Mapping Review, Claude proposes a profile)."],
  ["F-03 Assigning a shared issue overwrote other reviewers' rows", "Taking an issue is refused if any of its rows is assigned to someone else; giving it back releases only your own rows."],
  ["F-09 Two jobs could stage the same file", "The batch is locked (FOR UPDATE) and moved to Processing before anything else."],
  ["F-10 An amount too large for the field failed the whole file", "Amounts of 10^16 or more are a row error ('too large'); mirrored in the Python port with three new vectors (Number(18,2) holds 16 digits before the point)."],
  ["F-12 A long flag list could cut the last flag in half", "Whole flags are kept and any that do not fit are dropped; FOLLOW_UP_CLOSED is always kept last."],
], [3000, 6360]));
add(H2("19.2 Repository fixes"));
add(B("README counts corrected (42 Jest tests, not 50; 159 Apex tests) and the push-job setup steps written into the README instead of linking a guide that was not in the repository. The run guides for phases 1 to 3B are now included."));
add(B("PROJECT_CONTEXT.md (working notes with the org username and our working agreements) is git-ignored and kept in the Claude Project; a public ARCHITECTURE.md carries the technical content. The org username was removed from the JWT setup guide."));
add(B("Prettier: an Apex override (tab width 4, print width 160) and every Apex file reformatted to it, so the pre-commit hook no longer rewrites the codebase (verified: only whitespace changed). Sample CSVs keep their line endings (*.csv -text). Unused CSS removed, a misplaced comment moved, package name set, template leftovers removed from the repository."));
add(H2("19.3 Verification"));
add(B("159 Apex tests in 22 classes (new: team member choice, one code review per firm, assignment never takes others' rows, confirmed trade date, whole flags, processing lock, another dealer's profile, oversized amount). Parse, PMD (zero findings), lint, cross-reference, Python vectors (18 amounts), 42 Jest tests."));
add(H3("Field definition"));
live["Import_Staging_Row__c@4B4"].forEach((f) => add(fieldBlock(f)));

// ------------------------------------------------------------------ document
const doc = new Document({
  creator: "Greg Baronian",
  title: "Trade Import Reconciliation - Build Log and Architecture",
  styles: {
    default: { document: { run: { font: FONT, size: 21 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 32, bold: true, color: ACCENT, font: FONT }, paragraph: { spacing: { before: 360, after: 160 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, color: "2E75B6", font: FONT }, paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 1 } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 22, bold: true, color: "404040", font: FONT }, paragraph: { spacing: { before: 200, after: 100 }, outlineLevel: 2 } },
    ],
  },
  numbering: {
    config: [
      { reference: "bullets", levels: [
        { level: 0, format: LevelFormat.BULLET, text: "\u2022", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 270 } } } },
        { level: 1, format: LevelFormat.BULLET, text: "\u2013", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 1080, hanging: 270 } } } },
      ] },
      ...["num1", "num2"].map((r) => ({ reference: r, levels: [
        { level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 360 } } } },
      ] })),
    ],
  },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, bottom: 1440, left: 1440, right: 1440 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [
      new TextRun({ text: "Trade Import Reconciliation  |  Page ", size: 16, color: "808080" }),
      new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "808080" }),
    ] })] }) },
    children,
  }],
});
Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(__dirname + "/Trade_Import_Build_Log.docx", buf);
  console.log("written");
});
