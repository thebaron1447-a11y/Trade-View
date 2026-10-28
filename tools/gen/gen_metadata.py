"""Generates phase 1 SFDX metadata for the trade import demo."""
import os
from xml.sax.saxutils import escape

ROOT = "build/force-app/main/default"
NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"'


def w(path, content):
    full = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(content)


def x(s):
    return escape(s)


# ---------------------------------------------------------------- objects
OBJECTS = {
    "Rep_Code__c": dict(
        label="Rep Code", plural="Rep Codes", sharing="ReadWrite",
        name=dict(type="Text", label="Rep Code"),
        desc="A dealer/rep code issued by a firm. Linked to one or more advisors through Rep Code Assignments, which hold each advisor's share and effective dates. Code plus Firm is unique (enforced in Apex in a later phase)."),
    "Rep_Code_Assignment__c": dict(
        label="Rep Code Assignment", plural="Rep Code Assignments", sharing="ControlledByParent",
        name=dict(type="AutoNumber", label="Assignment Number", fmt="RCA-{00000}"),
        desc="Junction between a Rep Code and an Advisor (Contact) for a period of time, with the advisor's allocation percent. Solo codes have one assignment at 100%. Holds the effective dates used for reassignment detection."),
    "Trade__c": dict(
        label="Trade", plural="Trades", sharing="ReadWrite",
        name=dict(type="AutoNumber", label="Trade Number", fmt="TRD-{000000}"),
        desc="A single fund purchase or redemption received from an external firm, matched to the Rep Code that placed it. Advisor credit lives on the Trade Allocation children, never on the trade itself."),
    "Trade_Allocation__c": dict(
        label="Trade Allocation", plural="Trade Allocations", sharing="ControlledByParent",
        name=dict(type="AutoNumber", label="Allocation Number", fmt="TA-{000000}"),
        desc="One advisor's share of a trade, snapshotted at load time from the Rep Code Assignments in effect on the trade date. Summing Allocated Amount by advisor and fund gives cumulative net sales (the team's AUM). Advisor-level reporting must use this object, not Trade."),
    "Firm_Alias__c": dict(
        label="Firm Alias", plural="Firm Aliases", sharing="ReadWrite",
        name=dict(type="Text", label="Alias"),
        desc="An approved spelling of a firm or branch name as it appears in incoming files. The Name holds the raw variant; Normalized Key holds the NameNormalizer output used for lookup."),
    "Fund_Alias__c": dict(
        label="Fund Alias", plural="Fund Aliases", sharing="ReadWrite",
        name=dict(type="Text", label="Alias"),
        desc="An approved spelling of a fund name as it appears in incoming files, mapped to the Fund (Product2). Ambiguous variants are deliberately not aliased so they route to review."),
}


def object_xml(o):
    n = o["name"]
    name_inner = f"        <label>{x(n['label'])}</label>\n"
    if n["type"] == "AutoNumber":
        name_inner = f"        <displayFormat>{n['fmt']}</displayFormat>\n" + name_inner
    name_inner += f"        <type>{n['type']}</type>\n"
    flag = "true"
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomObject {NS}>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>{x(o['desc'])}</description>
    <enableActivities>false</enableActivities>
    <enableBulkApi>{flag}</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>{flag}</enableSharing>
    <enableStreamingApi>{flag}</enableStreamingApi>
    <externalSharingModel>{o['sharing']}</externalSharingModel>
    <label>{x(o['label'])}</label>
    <nameField>
{name_inner}    </nameField>
    <pluralLabel>{x(o['plural'])}</pluralLabel>
    <sharingModel>{o['sharing']}</sharingModel>
    <visibility>Public</visibility>
</CustomObject>
"""


# ---------------------------------------------------------------- fields
# kind: lookup, md, date, text, percent, currency, picklist, formula, summary
F = []


def field(obj, api, label, kind, desc, help_text=None, **kw):
    F.append(dict(obj=obj, api=api, label=label, kind=kind, desc=desc, help=help_text, **kw))


# Rep Code
field("Rep_Code__c", "Firm__c", "Firm", "lookup",
      "The firm that issued the code. Rep codes are only meaningful within a firm, so every Tier 1 match filters on this field.",
      "The firm that issued this code.",
      ref="Account", rel="Rep_Codes", rel_label="Rep Codes", required=True)
field("Rep_Code__c", "Active_Allocation_Total__c", "Active Allocation Total", "summary",
      "Total allocation across assignments with no end date. A validation rule blocks it from exceeding 100. Under 100 means a team member left without a new split; processing routes those trades to review. Display and validation only: processing calculates the split in effect on each trade date.",
      "Should equal 100%. If it is lower, someone's share needs to be reassigned before trades can load.")

# Rep Code Assignment
A = "Rep_Code_Assignment__c"
field(A, "Rep_Code__c", "Rep Code", "md",
      "The code this assignment belongs to. Master-detail so allocations roll up to the code's Active Allocation Total.",
      "The dealer code this advisor shares or holds.",
      ref="Rep_Code__c", rel="Assignments", rel_label="Assignments")
field(A, "Advisor__c", "Advisor", "lookup",
      "The advisor receiving a share of trades on this code during the effective period.",
      "The advisor who receives a share of this code's trades.",
      ref="Contact", rel="Rep_Code_Assignments", rel_label="Rep Code Assignments", required=True)
field(A, "Allocation_Percent__c", "Allocation Percent", "percent",
      "This advisor's share of trades on the code. Active assignments on a code must total 100. Solo codes use 100.",
      "This advisor's share of each trade, for example 60. All advisors on the code must add up to 100.",
      required=True)
field(A, "Effective_Start_Date__c", "Effective Start Date", "date",
      "First date this advisor held the code. Tier 1 matching requires the trade date to be on or after this date.",
      "The date the advisor started using this code.", required=True)
field(A, "Effective_End_Date__c", "Effective End Date", "date",
      "Last date this advisor is known to have held the code. Firms do not report transfers, so this is normally set by the system when a reviewer confirms a suspected reassignment, using Last Confirmed Trade Date as the boundary. Blank means no reassignment has been detected; it does not prove the code is still held by this advisor.",
      "The last date this advisor is known to have used this code. Usually set automatically when a code transfer is confirmed during review.")
field(A, "Last_Confirmed_Trade_Date__c", "Last Confirmed Trade Date", "date",
      "Trade date of the most recent loaded trade confirmed under this code and advisor. Updated by the load job. Used to detect dormant codes reactivating and as the inferred end-date boundary when a reassignment is confirmed.",
      "The most recent trade confirmed for this advisor under this code. System-maintained. Do not edit.")
field(A, "End_Date_Source__c", "End Date Source", "picklist",
      "How the Effective End Date was established. Lets auditors distinguish dates the system inferred from dates verified externally.",
      "Select how the end date was confirmed. Choose Inferred from Review if it was set from trade data alone.",
      values=["Inferred from Review", "Confirmed by Firm", "Confirmed via Registration Search"])

# Trade
T = "Trade__c"
field(T, "Rep_Code__c", "Rep Code", "lookup",
      "The rep code that placed the trade, as resolved by matching. Advisor credit comes from this code's assignments in effect on the Trade Date.",
      "The dealer code this trade was placed under.",
      ref="Rep_Code__c", rel="Trades", rel_label="Trades", required=True)
field(T, "Fund__c", "Fund", "lookup",
      "The fund traded, resolved from the raw fund name in the file through the Fund Alias table. Needed to report net sales by fund.",
      "The fund that was bought or sold.",
      ref="Product2", rel="Trades", rel_label="Trades", required=False)
field(T, "Trade_Date__c", "Trade Date", "date",
      "Date the trade was placed, as reported by the source firm. Determines which Rep Code Assignments (and splits) apply.",
      "The date the trade was placed.", required=True)
field(T, "Transaction_Type__c", "Transaction Type", "picklist",
      "Direction of the trade, normalized by each source firm's mapping profile regardless of whether the firm signals direction with a type column or a negative amount. Drives the sign of Signed Amount.",
      "Whether the fund was bought (Purchase) or sold (Redemption).",
      values=["Purchase", "Redemption"], required=True)
field(T, "Amount__c", "Amount", "currency",
      "Gross dollar amount of the trade, always stored as a positive number. A validation rule enforces Amount > 0, so direction lives only in Transaction Type.",
      "The dollar value of the trade, entered as a positive number.", required=True)
field(T, "Signed_Amount__c", "Signed Amount", "formula",
      "Amount with direction applied: positive for purchases, negative for redemptions. This is the value TradeAllocator splits across advisors.",
      "The trade amount as it affects net sales. Redemptions show as negative.",
      formula='IF(ISPICKVAL(Transaction_Type__c, "Redemption"), -Amount__c, Amount__c)')

# Trade Allocation
TA = "Trade_Allocation__c"
field(TA, "Trade__c", "Trade", "md",
      "The trade being allocated. Master-detail so allocations are deleted with the trade.",
      "The trade this allocation belongs to.",
      ref="Trade__c", rel="Trade_Allocations", rel_label="Trade Allocations")
field(TA, "Advisor__c", "Advisor", "lookup",
      "The advisor credited with this portion of the trade. Advisor-level reporting must use this object, not the trade, to avoid double counting.",
      "The advisor credited with this share.",
      ref="Contact", rel="Trade_Allocations", rel_label="Trade Allocations", required=True)
field(TA, "Allocation_Percent__c", "Allocation Percent", "percent",
      "Snapshot of the advisor's share on the trade date, copied at load time. Deliberately not a formula, so later split changes do not rewrite history.",
      "The advisor's share of this trade when it was loaded. Not updated if the team's split changes later.",
      required=True)
field(TA, "Allocated_Amount__c", "Allocated Amount", "currency",
      "This advisor's share of the trade's Signed Amount, calculated by TradeAllocator at load. Negative for redemptions, so summing by advisor and fund gives cumulative net sales (the team's AUM). Allocations for a trade always sum exactly to the Signed Amount.",
      "The advisor's share of this trade. Redemptions appear as negative amounts.", required=True)

# Aliases
for obj, ref, rel, rel_label, what in [
    ("Firm_Alias__c", "Account", "Firm_Aliases", "Firm Aliases", "firm"),
    ("Fund_Alias__c", "Product2", "Fund_Aliases", "Fund Aliases", "fund"),
]:
    field(obj, "Normalized_Key__c", "Normalized Key", "text",
          "Output of NameNormalizer.firmKey() for the alias. Indexed (External ID) for fast lookup. Deliberately not unique: if a key maps to more than one record, the row is sent to review instead of auto-resolving.",
          "System-generated matching key. Do not edit.", length=255, external_id=True)
    api = "Firm__c" if what == "firm" else "Fund__c"
    label = "Firm" if what == "firm" else "Fund"
    field(obj, api, label, "lookup",
          f"The {what} this name variant refers to. Created when a reviewer approves a new variant, so the same spelling resolves automatically next time.",
          f"The {what} this spelling refers to.",
          ref=ref, rel=rel, rel_label=rel_label, required=(ref != "Product2"))


# ================================================================ PHASE 2
OBJECTS.update({
    "Import_Batch__c": dict(
        label="Import Batch", plural="Import Batches", sharing="ReadWrite",
        name=dict(type="AutoNumber", label="Batch Number", fmt="IB-{000000}"),
        desc="One trade file received from an external firm, and its lifecycle from receipt through normalization, matching, review and load. Created by the inbound REST endpoint; the raw file is attached as a ContentVersion."),
    "Import_Staging_Row__c": dict(
        label="Import Staging Row", plural="Import Staging Rows", sharing="ControlledByParent",
        name=dict(type="AutoNumber", label="Row Id", fmt="ISR-{0000000}"),
        desc="One row of a received file, kept raw (as JSON) and normalized into canonical fields using the batch's mapping profile. Matching (phase 3) and loading (phase 4) work from these rows."),
    "Mapping_Profile__c": dict(
        label="Mapping Profile", plural="Mapping Profiles", sharing="ReadWrite",
        name=dict(type="Text", label="Profile Name"),
        desc="A saved column mapping and format settings for one source file layout. Selected automatically by matching the file's header fingerprint. Created by admins or, from phase 3, proposed by Claude and confirmed by a reviewer."),
})

IB, SR, MP = "Import_Batch__c", "Import_Staging_Row__c", "Mapping_Profile__c"
field(IB, "Status__c", "Status", "picklist",
      "Lifecycle stage of an import batch. Received is set by the inbound endpoint. Mapping Review means no active mapping profile matched the file's headers, or the matching profile is incomplete. Staged means every row was normalized into staging rows and the batch is ready for matching. Later values are used from phase 3. Set by Apex only.",
      "Shows where this import is in the process. Mapping Review and Pending Review batches are waiting on a reviewer.",
      values=["Received", "Mapping Review", "Processing", "Staged", "Pending Review", "Approved", "Loading", "Completed", "Rejected", "Failed"])
field(IB, "Source_Firm__c", "Source Firm", "text",
      "Code of the firm that sent the file, supplied by the push job (the firm's folder name in the data lake). Used to choose between mapping profiles and shown to reviewers for context.",
      "The external firm this trade file came from.", length=80)
field(IB, "Source_File_Name__c", "Source File Name", "text",
      "Original file name from the data lake, kept for traceability between the source system and Salesforce.",
      "The original name of the file as it arrived from the data lake.", length=255)
field(IB, "File_Hash__c", "File Hash", "text",
      "SHA-256 hash of the raw file contents, computed by the inbound endpoint and checked against the push job's own hash. Unique, so the same file can never be loaded twice when a job is re-run.",
      "System-generated fingerprint used to block duplicate imports. Do not edit.", length=64, unique=True, external_id=True)
field(IB, "Mapping_Profile__c", "Mapping Profile", "lookup",
      "The mapping profile applied to this file. Blank while the batch is in Mapping Review because no profile matched. Recorded so every batch shows exactly which column mapping produced its staging rows.",
      "The saved column mapping used to read this file.",
      ref="Mapping_Profile__c", rel="Import_Batches", rel_label="Import Batches", required=False)
field(IB, "Row_Count__c", "Row Count", "number",
      "Number of non-blank data rows parsed from the file, excluding the header. Used in the reconciliation check: rows in must equal rows loaded plus rows rejected.",
      "How many trade rows were in the file.", precision=6, scale=0)
field(IB, "Error_Row_Count__c", "Error Row Count", "summary",
      "Number of staging rows with validation errors. Rows with errors are never matched or loaded until corrected.",
      "How many rows in this file have problems that must be fixed.",
      summary=dict(op="count", fk="Import_Staging_Row__c.Import_Batch__c",
                   filt=("Import_Staging_Row__c.Has_Errors__c", "equals", "True")))
field(IB, "Error_Message__c", "Error Message", "longtext",
      "Reason the batch failed or stopped at Mapping Review (parse error, incomplete mapping profile, unexpected exception). Shown to reviewers and included in notifications.",
      "Explains why this import failed or needs a mapping review, if it did.", length=5000, lines=3)

field(SR, "Import_Batch__c", "Import Batch", "md",
      "The batch this row belongs to. Master-detail so rows are deleted with the batch and can be counted with roll-ups.",
      "The import this row came from.",
      ref="Import_Batch__c", rel="Staging_Rows", rel_label="Staging Rows")
field(SR, "Row_Number__c", "Row Number", "number",
      "Position of the row among the file's non-blank data rows (1 = first data row after the header). Lets reviewers and firms trace any staging row back to the original file.",
      "The position of this row in the original file.", precision=6, scale=0)
field(SR, "Raw_Data__c", "Raw Data", "longtext",
      "The original row as JSON, keyed by the file's own column headers, before any mapping. Kept unchanged for audit and so a corrected mapping profile can be re-applied without re-sending the file.",
      "The row exactly as it appeared in the file. Do not edit.", length=32768, lines=5)
field(SR, "Source_Rep_Code__c", "Source Rep Code", "text",
      "Rep code from the file after normalization: whitespace removed, upper-cased, and leading zeros removed from all-numeric codes. Input to Tier 1 matching.",
      "The dealer code reported in the file.", length=40)
field(SR, "Source_Advisor_Name__c", "Source Advisor Name", "text",
      "Advisor name as reported in the file, with extra spaces removed. Used for name corroboration and to detect possible rep code reassignments.",
      "The advisor name reported in the file, if any.", length=255)
field(SR, "Source_Firm_Name__c", "Source Firm Name", "text",
      "Firm or branch name as reported in the file. When blank and the mapping profile is a single-firm feed, filled with the profile's firm name. Resolved to an Account through the Firm Alias table.",
      "The firm name reported in the file, if any.", length=255)
field(SR, "Source_Fund_Name__c", "Source Fund Name", "text",
      "Fund name as reported in the file. Resolved to a Fund (Product2) through the Fund Alias table.",
      "The fund name reported in the file.", length=255)
field(SR, "Trade_Date__c", "Row Date", "date",
      "Date from the row, parsed with the mapping profile's declared date format and never guessed: the trade date for Trade rows, the as-of date for AUM rows, or the effective date for Code Roster rows. API name kept from phase 2 to avoid breaking deployed code. Blank if the value could not be parsed (see Validation Errors).",
      "The trade date, AUM as-of date or code effective date, depending on the row type.")
field(SR, "Transaction_Type__c", "Transaction Type", "picklist",
      "Direction of the trade, derived using the profile's direction convention: a type column (BUY/SELL, ACHAT/RACHAT and similar) or the sign of the amount.",
      "Whether the fund was bought or sold.", values=["Purchase", "Redemption"])
field(SR, "Amount__c", "Amount", "currency",
      "For Trade rows, the gross trade amount as a positive number after removing currency symbols, thousands separators and any sign used to indicate direction. For AUM rows, the reported balance (zero or more). Blank for Code Roster rows. Rounded to 2 decimals.",
      "The dollar value of the trade, or the AUM balance for AUM rows.")
field(SR, "Validation_Errors__c", "Validation Errors", "longtext",
      "Problems found while normalizing the row, one per line (unparseable date, missing amount, unknown transaction type, wrong number of columns). A row with errors is never matched or loaded.",
      "Lists anything wrong with this row that must be fixed before it can load.", length=5000, lines=3)
field(SR, "Has_Errors__c", "Has Errors", "checkbox",
      "True when Validation Errors is not blank. Set by Apex. Exists because roll-up summaries cannot filter on long text fields; drives Import Batch Error Row Count.",
      "Checked when this row has validation errors. Set automatically.")

field(MP, "Source_Firm__c", "Source Firm", "text",
      "Firm code this profile reads files for, matching Import Batch Source Firm. Used to choose between profiles when two firms send identical layouts.",
      "The firm code whose files this mapping reads.", length=80)
field(MP, "Firm__c", "Firm", "lookup",
      "The firm Account this feed belongs to. When Single Firm Feed is checked, its name fills in a missing firm on every row.",
      "The firm this feed belongs to.",
      ref="Account", rel="Mapping_Profiles", rel_label="Mapping Profiles", required=False)
field(MP, "Header_Fingerprint__c", "Header Fingerprint", "text",
      "SHA-256 of the file's normalized header row (trimmed, lower-cased, single-spaced, joined with |). Used to pick the profile automatically. External ID for fast lookup; not unique, because a Draft and an Active version can share a layout.",
      "System-generated identifier for the file layout. Do not edit.", length=64, external_id=True)
field(MP, "Column_Map__c", "Column Map", "longtext",
      "JSON object mapping each source column header to a canonical field: repCode, advisorName, firmName, fundName, tradeDate, amount, transactionType, or IGNORE. Every column in the file must appear, so nothing is silently dropped.",
      "How each column in the file maps to a trade field. Every column must be mapped or marked IGNORE.", length=32768, lines=8)
field(MP, "Date_Format__c", "Date Format", "picklist",
      "Date format used by this source. Declared once per profile because dates like 03/04/2026 are ambiguous row by row. A value that does not fit the format is flagged, not guessed.",
      "The date format this firm uses in its files.", values=["MM/DD/YYYY", "DD/MM/YYYY", "YYYY-MM-DD"], required=True)
field(MP, "Decimal_Separator__c", "Decimal Separator", "picklist",
      "Decimal separator used in amounts. Period means 1,234.56. Comma means 1 234,56 or 1.234,56, common in French-language exports.",
      "Choose Comma if this firm writes amounts like 1 234,56.", values=["Period", "Comma"], required=True)
field(MP, "Direction_Convention__c", "Direction Convention", "picklist",
      "How this source indicates buys versus sells. Type Column requires a transactionType column. Signed Amount means negative amounts are redemptions, and a transactionType column is not allowed.",
      "How this firm shows whether a trade is a purchase or a redemption.", values=["Type Column", "Signed Amount"], required=True)
field(MP, "Single_Firm_Feed__c", "Single Firm Feed", "checkbox",
      "When checked, the profile's Firm fills in a missing firm name on rows from this feed. Leave unchecked for aggregator feeds that contain multiple dealers.",
      "Check only if every row in this feed always comes from the same firm.")
field(MP, "Status__c", "Status", "picklist",
      "Only Active profiles are used to read files. Draft profiles are proposed mappings awaiting confirmation (phase 3). Retired profiles are kept so past batches remain explainable.",
      "Only Active mappings are used. Retire old mappings instead of deleting them.", values=["Draft", "Active", "Retired"], required=True)

VRS_P2 = [
    (MP, "Column_Map_Required_When_Active", "AND(ISPICKVAL(Status__c, \"Active\"), ISBLANK(Column_Map__c))", "Column_Map__c",
     "An Active mapping profile needs a Column Map.", "Prevents activating a profile that cannot map any columns."),
    (MP, "Fingerprint_Required_When_Active", "AND(ISPICKVAL(Status__c, \"Active\"), ISBLANK(Header_Fingerprint__c))", "Header_Fingerprint__c",
     "An Active mapping profile needs a Header Fingerprint.", "Without a fingerprint the profile can never be selected."),
    (MP, "Firm_Required_For_Single_Firm_Feed", "AND(Single_Firm_Feed__c, ISBLANK(Firm__c))", "Firm__c",
     "Select the Firm when Single Firm Feed is checked.", "Single-firm feeds fill missing firm names from this lookup."),
]

LAYOUTS_P2 = {
    IB: dict(
        left=[("Name", "Readonly"), ("Status__c", "Readonly"), ("Source_Firm__c", "Readonly"),
              ("Source_File_Name__c", "Readonly"), ("Mapping_Profile__c", "Edit")],
        right=[("Row_Count__c", "Readonly"), ("Error_Row_Count__c", "Readonly"), ("Matched_Row_Count__c", "Readonly"),
               ("Review_Row_Count__c", "Readonly"), ("Held_Row_Count__c", "Readonly"), ("File_Hash__c", "Readonly"),
               ("Error_Message__c", "Readonly"), ("OwnerId", "Edit")],
        related=[("Import_Staging_Row__c.Import_Batch__c",
                  ["NAME", "Row_Number__c", "Row_Type__c", "Source_Rep_Code__c", "Source_Advisor_Name__c", "Source_Fund_Name__c",
                   "Trade_Date__c", "Amount__c", "Match_Status__c", "Match_Flags__c"])],
        listcols=["NAME", "Status__c", "Source_Firm__c", "Source_File_Name__c", "Row_Count__c", "Matched_Row_Count__c",
                  "Review_Row_Count__c", "Held_Row_Count__c", "Error_Row_Count__c"]),
    SR: dict(
        left=[("Name", "Readonly"), ("Import_Batch__c", "Required"), ("Row_Number__c", "Readonly"), ("Row_Type__c", "Edit"),
              ("Source_Rep_Code__c", "Edit"), ("Source_Advisor_Name__c", "Edit"), ("Source_Firm_Name__c", "Edit"),
              ("Source_Branch_Name__c", "Edit"), ("Source_Fund_Name__c", "Edit"), ("Trade_Date__c", "Edit"),
              ("Transaction_Type__c", "Edit"), ("Amount__c", "Edit")],
        right=[("Match_Status__c", "Edit"), ("Match_Method__c", "Readonly"), ("Matched_Firm__c", "Edit"),
               ("Matched_Rep_Code__c", "Edit"), ("Matched_Fund__c", "Edit"), ("Credited_Advisor__c", "Edit"),
               ("Code_Follow_Up__c", "Edit"), ("Match_Flags__c", "Readonly"), ("Has_Errors__c", "Readonly")],
        related=[],
        listcols=["NAME", "Import_Batch__c", "Row_Number__c", "Row_Type__c", "Source_Rep_Code__c", "Source_Fund_Name__c",
                  "Trade_Date__c", "Amount__c", "Match_Status__c", "Match_Flags__c"]),
    MP: dict(
        left=[("Name", "Required"), ("Status__c", "Required"), ("Feed_Type__c", "Edit"), ("Source_Firm__c", "Edit"),
              ("Firm__c", "Edit"), ("Single_Firm_Feed__c", "Edit"), ("AUM_Indicator_Values__c", "Edit")],
        right=[("Date_Format__c", "Required"), ("Decimal_Separator__c", "Required"),
               ("Direction_Convention__c", "Required"), ("Header_Fingerprint__c", "Edit"), ("Column_Map__c", "Edit")],
        related=[("Import_Batch__c.Mapping_Profile__c", ["NAME", "Status__c", "Source_File_Name__c", "Row_Count__c"])],
        listcols=["NAME", "Status__c", "Source_Firm__c", "Date_Format__c", "Direction_Convention__c",
                  "Single_Firm_Feed__c"]),
}

# ================================================================ PHASE 3A
CF = "Code_Follow_Up__c"
OBJECTS[CF] = dict(
    label="Code Follow-Up", plural="Code Follow-Ups", sharing="ReadWrite",
    name=dict(type="AutoNumber", label="Follow-Up Number", fmt="CFU-{00000}"),
    desc="To-do item for a dealer code that is unknown, ended, dormant, suspected reassigned or incompletely split. Rows on that code are held, never orphaned, until someone resolves the follow-up; resolving it re-matches the held rows automatically.")

field(MP, "Feed_Type__c", "Feed Type", "picklist",
      "Kind of file this profile reads. Trade Activity files contain trade rows and AUM rows mixed together. Advisor Code Roster files list dealer codes and the advisors who hold them, and feed code setup rather than trades. Blank is treated as Trade Activity.",
      "Choose Advisor Code Roster for files that list advisor codes; otherwise Trade Activity.",
      values=["Trade Activity", "Advisor Code Roster"], default="Trade Activity")
field(MP, "AUM_Indicator_Values__c", "AUM Indicator Values", "text",
      "Comma-separated values that mark a row as AUM rather than a trade, for example AUM, BAL, POSITION. Compared case-insensitively against the column mapped to rowType, or the transactionType column when no rowType column exists. Blank means the file has no AUM rows.",
      "List the values this firm uses to mark AUM rows, separated by commas.", length=255)

field(SR, "Row_Type__c", "Row Type", "picklist",
      "Kind of row after normalization. Drives which validations apply, which matching rules run and what the row becomes when loaded (Trade, AUM Snapshot or Rep Code Assignment).",
      "Shows whether this row is a trade, an AUM balance or an advisor code entry.",
      values=["Trade", "AUM", "Code Roster"])
field(SR, "Source_Branch_Name__c", "Source Branch Name", "text",
      "Branch name as reported in the file. Used to place new advisors from code roster files and as a signal when detecting code reassignments.",
      "The branch name reported in the file, if any.", length=255)
field(SR, "Match_Status__c", "Match Status", "picklist",
      "Outcome of matching. Pending: not yet matched (or released for re-matching). Matched: firm, code and advisor credit resolved. Needs Review: ambiguous; Claude suggests and a reviewer decides. Held: waiting on a Code Follow-Up. Invalid: the row has validation errors and is never matched. Rejected: a reviewer decided the row must not be loaded.",
      "Where this row is in matching.",
      values=["Pending", "Matched", "Needs Review", "Held", "Invalid", "Rejected"], default="Pending")
field(SR, "Matched_Firm__c", "Matched Firm", "lookup",
      "Firm Account resolved from the row's firm name through the Firm Alias table (exact key, or a close fuzzy match accepted automatically). Blank when the firm is unresolved or ambiguous.",
      "The firm this row was matched to.",
      ref="Account", rel="Matched_Staging_Rows", rel_label="Matched Staging Rows", required=False)
field(SR, "Matched_Rep_Code__c", "Matched Rep Code", "lookup",
      "Rep Code record found for the row's code at the matched firm. Blank for codes not yet set up in Salesforce (those rows are held on a Code Follow-Up).",
      "The dealer code record this row belongs to.",
      ref="Rep_Code__c", rel="Staging_Rows", rel_label="Staging Rows", required=False)
field(SR, "Matched_Fund__c", "Matched Fund", "lookup",
      "Fund resolved from the row's fund name through the Fund Alias table. Required for Trade rows; optional for AUM rows reported as a total per code. Lookups to Product2 must be optional and clear on delete.",
      "The fund this row was matched to.",
      ref="Product2", rel="Staging_Rows", rel_label="Staging Rows", required=False)
field(SR, "Credited_Advisor__c", "Credited Advisor", "lookup",
      "Set by matching when the whole row is credited to one advisor: a solo code, or a team code where the row names exactly one active member (confirmed rule: 100% to that person). Blank means the row splits by the team's percentages.",
      "The advisor who receives full credit for this row, when it is not split across a team.",
      ref="Contact", rel="Credited_Staging_Rows", rel_label="Credited Staging Rows", required=False)
field(SR, "Code_Follow_Up__c", "Code Follow-Up", "lookup",
      "The follow-up holding this row because its code is unknown, ended, dormant, suspected reassigned or incompletely split. Held rows are never loaded or orphaned; they are re-matched automatically when the follow-up is resolved.",
      "The follow-up item this row is waiting on, if any.",
      ref=CF, rel="Held_Rows", rel_label="Held Rows", required=False)
field(SR, "Match_Method__c", "Match Method", "picklist",
      "How the row was resolved: Exact (alias key and code lookup), Fuzzy (a close name match accepted automatically), Claude (a reviewer accepted Claude's suggested firm or fund) or Reviewer (a reviewer chose the firm or fund, or approved a roster row).",
      "How this row was matched.", values=["Exact", "Fuzzy", "Claude", "Reviewer"])
field(SR, "Match_Flags__c", "Match Flags", "text",
      "Semicolon-separated machine-readable flags explaining the outcome, for example FUND_UNRESOLVED;DORMANT_CODE_REACTIVATED. Used for filtering, reporting and the review screen.",
      "Short codes explaining why this row was matched, held or sent to review.", length=255)
field(SR, "Match_Notes__c", "Match Notes", "longtext",
      "Plain-language explanation of the matching outcome, one finding per line, written for reviewers.",
      "What matching found for this row, in plain language.", length=5000, lines=3)
field(SR, "Match_Candidates__c", "Match Candidates", "longtext",
      "JSON list of candidate firms or funds with similarity scores, kept when a name could not be resolved automatically. Input to review and to Claude in the next drop.",
      "Possible matches considered for this row. System-maintained.", length=32768, lines=3)

for api, label, value, desc, help_ in [
    ("Matched_Row_Count__c", "Matched Row Count", "Matched", "Number of staging rows matched deterministically.", "How many rows were matched automatically."),
    ("Review_Row_Count__c", "Review Row Count", "Needs Review", "Number of staging rows needing a reviewer decision.", "How many rows need a review decision."),
    ("Held_Row_Count__c", "Held Row Count", "Held", "Number of staging rows held on Code Follow-Ups.", "How many rows are on hold waiting for code follow-up."),
]:
    field(IB, api, label, "summary", desc, help_,
          summary=dict(op="count", fk="Import_Staging_Row__c.Import_Batch__c",
                       filt=("Import_Staging_Row__c.Match_Status__c", "equals", value)))

field(CF, "Rep_Code_Value__c", "Rep Code Value", "text",
      "The code exactly as normalized from the file. Needed because an unknown code has no Rep Code record to look up.",
      "The dealer code that needs follow-up.", length=40)
field(CF, "Rep_Code__c", "Rep Code", "lookup",
      "The existing Rep Code record when the code is known but ended, dormant, suspected reassigned or incompletely split. Blank for codes never set up.",
      "The code record, if the code already exists in Salesforce.",
      ref="Rep_Code__c", rel="Code_Follow_Ups", rel_label="Code Follow-Ups", required=False)
field(CF, "Firm__c", "Firm", "lookup",
      "The firm the code belongs to, from the row's resolved firm.",
      "The firm that issued this code.",
      ref="Account", rel="Code_Follow_Ups", rel_label="Code Follow-Ups", required=False)
field(CF, "Reason__c", "Reason", "picklist",
      "Why the rows are held. Unknown Code: no Rep Code exists. Code Ended: all assignments ended before the row date. Code Dormant: no confirmed activity within the dormancy threshold and no advisor name to confirm the holder. Reassignment Suspected: the advisor named does not match any current holder. Allocation Incomplete: a team split is needed but active shares do not total 100%.",
      "Why trades on this code are on hold.",
      values=["Unknown Code", "Code Ended", "Code Dormant", "Reassignment Suspected", "Allocation Incomplete"], required=True)
field(CF, "Status__c", "Status", "picklist",
      "Lifecycle of the follow-up. Moving to Resolved re-matches all held rows; Closed - No Action sends them to manual review instead. A resolved follow-up is reopened if new rows are held for the same reason.",
      "Set to In Progress while you chase the information, and Resolved once the code is set up.",
      values=["Open", "In Progress", "Resolved", "Closed - No Action"], required=True, default="Open")
field(CF, "Follow_Up_Key__c", "Follow-Up Key", "text",
      "Source firm, code and reason joined, for example NORTHGATE|5521|Code Dormant. Unique, so repeat files add rows to the existing follow-up instead of creating duplicates.",
      "System-generated. Do not edit.", length=255, unique=True, external_id=True)
field(CF, "Held_Row_Count__c", "Held Row Count", "number",
      "Number of staging rows currently held by this follow-up. Maintained by Apex because rows link by lookup, which roll-up summaries cannot count.",
      "How many rows are waiting on this follow-up.", precision=6, scale=0)
field(CF, "Held_Amount__c", "Held Amount", "currency",
      "Total dollar value of held Trade rows (AUM balances excluded), maintained by Apex. Lets the team work the most valuable follow-ups first.",
      "Total value of trades waiting on this follow-up.")
field(CF, "Last_Seen_Date__c", "Last Seen Date", "date",
      "Most recent row date seen on this code. Shows whether a dealer is still actively using the code.",
      "The latest date this code appeared in a file.")
field(CF, "Suggested_Resolution__c", "Suggested Resolution", "longtext",
      "Claude's explanation of who the code most likely belongs to and what to check, based on the held rows, the firm's advisors and their codes, and any roster rows for the code. A suggestion only: a person must confirm it.",
      "Claude's best guess at who this code belongs to. Verify before acting on it.", length=5000, lines=4)
field(CF, "Resolution_Notes__c", "Resolution Notes", "longtext",
      "What the person who worked the follow-up found and did, for audit.",
      "Record what you found and how you resolved it.", length=5000, lines=4)

LAYOUTS_P3 = {
    CF: dict(
        left=[("Name", "Readonly"), ("Status__c", "Required"), ("Reason__c", "Required"), ("Rep_Code_Value__c", "Edit"),
              ("Firm__c", "Edit"), ("Rep_Code__c", "Edit")],
        right=[("Held_Row_Count__c", "Readonly"), ("Held_Amount__c", "Readonly"), ("Last_Seen_Date__c", "Readonly"),
               ("Follow_Up_Key__c", "Readonly"), ("Assigned_To__c", "Edit"), ("OwnerId", "Edit")],
        related=[("Import_Staging_Row__c.Code_Follow_Up__c",
                  ["NAME", "Row_Type__c", "Source_Advisor_Name__c", "Source_Fund_Name__c", "Trade_Date__c", "Amount__c", "Match_Flags__c"])],
        listcols=["NAME", "Status__c", "Reason__c", "Rep_Code_Value__c", "Firm__c", "Held_Row_Count__c", "Held_Amount__c",
                  "Last_Seen_Date__c"]),
}
EXTRA_LAYOUT_ITEMS = {
    CF: dict(sections=[("Resolution", [("Suggested_Resolution__c", "Edit"), ("Resolution_Notes__c", "Edit")])]),
}
APEX_CLASSES = ["NameNormalizer", "CsvParser", "MappingService", "TradeRowNormalizer", "ImportBatchProcessor",
                "TradeIngestResource", "ProductDeleteGuard", "NameMatcher", "TradeMatcher", "CodeFollowUpService"]

# ================================================================ PHASE 3B
AL, MR = "AI_Request_Log__c", "Matching_Rule__c"
OBJECTS[AL] = dict(
    label="AI Request Log", plural="AI Request Logs", sharing="Read",
    name=dict(type="AutoNumber", label="Request Number", fmt="AIR-{00000}"),
    desc="One record per call to Claude through the Models API: the exact prompt, the raw response, the model, duration and whether the response passed validation. The audit trail for every AI suggestion; never edited after creation.")
OBJECTS[MR] = dict(
    label="Matching Rule", plural="Matching Rules", sharing="ReadWrite",
    name=dict(type="Text", label="Rule Name"),
    desc="A plain-language matching instruction taught by a reviewer, for one firm or all firms (for example: Barder writes ETF fund names with a leading ETF). Active rules are given to Claude with every suggestion request. Activation requires a second person when the AI setting says so.")

# Import Staging Row: Claude suggestion, reviewer decision
for api, label, ref, rel, rel_label, desc, help_ in [
    ("AI_Suggested_Firm__c", "AI Suggested Firm", "Account", "AI_Suggested_Staging_Rows", "AI Suggested Staging Rows",
     "Firm Claude suggests for a row whose firm name was missing, unresolved or ambiguous. Always one of the candidates sent to Claude; anything else is rejected by validation.",
     "The firm Claude thinks this row belongs to."),
    ("AI_Suggested_Fund__c", "AI Suggested Fund", "Product2", "AI_Suggested_Staging_Rows", "AI Suggested Staging Rows",
     "Fund Claude suggests for a row whose fund name was unresolved or ambiguous. Lookups to Product2 must be optional and clear on delete.",
     "The fund Claude thinks this row refers to."),
    ("AI_Suggested_Advisor__c", "AI Suggested Advisor", "Contact", "AI_Suggested_Staging_Rows", "AI Suggested Staging Rows",
     "Advisor Claude suggests for a roster row whose advisor name matched more than one person.",
     "The advisor Claude thinks this row refers to."),
    ("AI_Request__c", "AI Request", AL, "Staging_Rows", "Staging Rows",
     "The AI Request Log entry that produced this row's suggestion, so every suggestion can be traced to its exact prompt and response.",
     "The Claude request behind this suggestion."),
    ("Firm_Override__c", "Firm Override", "Account", "Override_Staging_Rows", "Override Staging Rows",
     "Firm chosen by a reviewer, or copied from Claude's suggestion when the reviewer accepts it. Matching uses it instead of the firm name in the file.",
     "Pick the correct firm if the file's firm name is wrong or ambiguous, then set Reviewer Decision to Accept."),
    ("Fund_Override__c", "Fund Override", "Product2", "Override_Staging_Rows", "Override Staging Rows",
     "Fund chosen by a reviewer, or copied from Claude's suggestion when the reviewer accepts it. Matching uses it instead of the fund name in the file.",
     "Pick the correct fund if the file's fund name is wrong or ambiguous, then set Reviewer Decision to Accept."),
]:
    field(SR, api, label, "lookup", desc, help_, ref=ref, rel=rel, rel_label=rel_label, required=False)
field(SR, "AI_Status__c", "AI Status", "picklist",
      "State of Claude's suggestion for this row. Blank: not requested yet. Suggested: a valid suggestion is stored. No Suggestion: Claude returned nothing for the row. Invalid: Claude's answer failed validation and was discarded. Failed: the call itself failed. Clear it to request a new suggestion.",
      "Whether Claude has suggested an answer for this row.", values=["Suggested", "No Suggestion", "Invalid", "Failed"])
field(SR, "AI_Confidence__c", "AI Confidence", "picklist",
      "Claude's stated confidence in its suggestion. Low means the evidence does not settle the question and a person should decide from scratch.",
      "How sure Claude is. Treat Low as no suggestion.", values=["High", "Medium", "Low"])
field(SR, "AI_Suggestion__c", "AI Suggestion", "longtext",
      "Claude's explanation of its suggestion, citing the evidence, written for the reviewer. For roster rows it also states whether to approve.",
      "Why Claude suggests this. Check the evidence before accepting.", length=5000, lines=4)
field(SR, "Reviewer_Decision__c", "Reviewer Decision", "picklist",
      "The reviewer's decision on a row in Needs Review. Accept: re-match the row using the Firm and Fund Overrides (filled from Claude's suggestion when left blank); on a roster row, apply it (create the advisor, code and assignment and resolve matching follow-ups). Reject: the row is not loaded. Recorded with who decided and when.",
      "Accept to apply the suggestion or your overrides, or Reject to exclude the row.", values=["Accept", "Reject"])
field(SR, "Remember_Choice__c", "Remember Choice", "checkbox",
      "When checked on Accept, the file's firm or fund spelling is saved as a new alias so future files match automatically. Only applies when the name was unresolved (not ambiguous), because an ambiguous spelling must keep going to review.",
      "Check to teach the system this spelling for future files.")
field(SR, "Decided_By__c", "Decided By", "lookup",
      "The user who set Reviewer Decision. Set by the system for audit.",
      "Who made the review decision.", ref="User", rel="Decided_Staging_Rows", rel_label="Decided Staging Rows", required=False)
field(SR, "Decided_At__c", "Decided At", "datetime",
      "When Reviewer Decision was set. Set by the system for audit.",
      "When the review decision was made.")

# Code Follow-Up: Claude suggestion
field(CF, "AI_Status__c", "AI Status", "picklist",
      "State of Claude's suggestion for this follow-up. Blank: not requested yet. Suggested, No Suggestion, Invalid or Failed as on staging rows. Clear it to request a new suggestion.",
      "Whether Claude has suggested who this code belongs to.", values=["Suggested", "No Suggestion", "Invalid", "Failed"])
field(CF, "AI_Confidence__c", "AI Confidence", "picklist",
      "Claude's stated confidence in its suggestion. Low means the evidence does not settle the question.",
      "How sure Claude is. Treat Low as no suggestion.", values=["High", "Medium", "Low"])
field(CF, "AI_Suggested_Advisor__c", "AI Suggested Advisor", "lookup",
      "The existing advisor Claude believes now holds the code, when one of the firm's advisors fits the evidence. Blank when the likely holder is not in Salesforce yet.",
      "The advisor Claude thinks holds this code.", ref="Contact", rel="AI_Suggested_Follow_Ups", rel_label="AI Suggested Follow-Ups", required=False)
field(CF, "AI_Request__c", "AI Request", "lookup",
      "The AI Request Log entry that produced this suggestion.",
      "The Claude request behind this suggestion.", ref=AL, rel="Code_Follow_Ups", rel_label="Code Follow-Ups", required=False)

# Import Batch: header fingerprint (for re-processing when a mapping is activated)
field(IB, "Header_Fingerprint__c", "Header Fingerprint", "text",
      "Fingerprint of the file's header row, saved when no Active mapping matched. When a mapping profile with this fingerprint is set to Active, waiting batches are re-processed automatically.",
      "Identifies the file layout. System-maintained.", length=64, external_id=True)

# Mapping Profile: Claude proposal
field(MP, "AI_Rationale__c", "AI Rationale", "longtext",
      "For profiles proposed by Claude: its explanation of each choice and its confidence, followed by the results of the same checks used when reading a file. Read this before setting the profile to Active.",
      "Why Claude proposed this mapping, and any problems found. Review before activating.", length=5000, lines=6)
field(MP, "Proposed_From_Batch__c", "Proposed From Batch", "lookup",
      "The import batch whose file Claude read to propose this profile.",
      "The file this mapping was proposed from.", ref=IB, rel="Proposed_Mapping_Profiles", rel_label="Proposed Mapping Profiles", required=False)

# AI Request Log
field(AL, "Purpose__c", "Purpose", "picklist",
      "What the request was for: suggestions on review rows and follow-ups, or a proposed mapping profile for an unknown file layout.",
      "What Claude was asked to do.", values=["Row Suggestions", "Mapping Proposal"], required=True)
field(AL, "Status__c", "Status", "picklist",
      "Success: Claude answered and the answer passed validation. Invalid Response: Claude answered but the answer was not valid JSON or broke the rules (unknown keys, bad values) and nothing was applied. Failed: the call did not complete.",
      "Whether the request succeeded.", values=["Success", "Invalid Response", "Failed"], required=True)
field(AL, "Provider__c", "Provider", "picklist",
      "Which route the request took. Models API: through the Einstein Trust Layer (Enterprise tier). Anthropic API: directly to Anthropic with the firm's own key (Standard tier). Set from the Trade AI Setting at the time of the call, so auditors can show which route every prompt took.",
      "Models API means the request went through the Einstein Trust Layer; Anthropic API means it went directly to Anthropic.",
      values=["Models API", "Anthropic API"], required=False)
field(AL, "Model_Name__c", "Model Name", "text",
      "Model used, from the Trade AI Setting custom metadata: a Models API name such as sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet, or an Anthropic model ID such as claude-sonnet-5-5.",
      "The Claude model that answered.", length=255)
field(AL, "Prompt__c", "Prompt", "longtext", "The exact prompt sent, for audit and prompt tuning.", "What was sent to Claude.", length=131072, lines=10)
field(AL, "Response__c", "Response", "longtext", "Claude's raw response text, before validation.", "What Claude answered.", length=131072, lines=10)
field(AL, "Error_Message__c", "Error Message", "longtext",
      "Why the call failed or the response was rejected, including each validation problem found.", "What went wrong, if anything.", length=5000, lines=3)
field(AL, "Item_Count__c", "Item Count", "number", "Number of rows and follow-ups (or files) included in the request.", "How many items were in the request.", precision=4, scale=0)
field(AL, "Duration_Ms__c", "Duration (ms)", "number", "Wall-clock time of the call in milliseconds.", "How long Claude took to answer.", precision=9, scale=0)
field(AL, "Import_Batch__c", "Import Batch", "lookup",
      "The batch the request was about, when it concerned a single batch (always for mapping proposals).",
      "The import this request relates to.", ref=IB, rel="AI_Requests", rel_label="AI Requests", required=False)

# Matching Rule
field(MR, "Firm__c", "Firm", "lookup",
      "The firm the rule applies to. Blank means the rule applies to every firm.",
      "Leave blank for a rule that applies to all firms.", ref="Account", rel="Matching_Rules", rel_label="Matching Rules", required=False)
field(MR, "Rule__c", "Rule", "longtext",
      "The instruction in plain language, as Claude will read it. Keep it to one fact or convention per rule.",
      "Describe one convention this firm uses, for example: ETF in a fund name always means the Wealth World ETF.", length=1000, lines=3)
field(MR, "Status__c", "Status", "picklist",
      "Proposed: drafted, not used. Active: sent to Claude with every suggestion request. Retired: kept for history. When two-person approval is on, the person who activates a rule must not be its author.",
      "Set to Active to start using the rule. Someone other than the author must activate it.",
      values=["Proposed", "Active", "Retired"], required=True, default="Proposed")
field(MR, "Approved_By__c", "Approved By", "lookup",
      "The user who activated the rule. Set by the system.",
      "Who activated this rule.", ref="User", rel="Approved_Matching_Rules", rel_label="Approved Matching Rules", required=False)
field(MR, "Approved_At__c", "Approved At", "datetime", "When the rule was activated. Set by the system.", "When this rule was activated.")

# ================================================================ PHASE 4B: review app
field(SR, "Assigned_To__c", "Assigned To", "lookup",
      "The reviewer who has taken this row in the Trade Review app, so two people never work the same item. Set and cleared from the app (Assign to me / Unassign); only the assignee can unassign. Blank means anyone can pick it up.",
      "Who is working on this row. Use Assign to me in Trade Review so others know it is taken.",
      ref="User", rel="Assigned_Review_Rows", rel_label="Assigned Review Rows", required=False)
field(CF, "Assigned_To__c", "Assigned To", "lookup",
      "The person who has taken this follow-up in the Trade Review app, so two people never chase the same dealer. Set and cleared from the app; only the assignee can unassign. Separate from Owner, which controls record access.",
      "Who is working on this follow-up. Use Assign to me in Trade Review so others know it is taken.",
      ref="User", rel="Assigned_Follow_Ups", rel_label="Assigned Follow-Ups", required=False)
APEX_CLASSES += ["FileIntakeService", "ReviewController"]

VRS_P3B = [
    (MR, "Rule_Required", "ISBLANK(Rule__c)", "Rule__c", "Describe the rule.",
     "A matching rule must say something for Claude to apply."),
]
LAYOUTS_P3B = {
    AL: dict(
        left=[("Name", "Readonly"), ("Purpose__c", "Readonly"), ("Status__c", "Readonly"), ("Provider__c", "Readonly"),
              ("Model_Name__c", "Readonly"), ("Import_Batch__c", "Readonly")],
        right=[("Item_Count__c", "Readonly"), ("Duration_Ms__c", "Readonly")],
        related=[("Import_Staging_Row__c.AI_Request__c", ["NAME", "Source_Firm_Name__c", "Source_Fund_Name__c", "AI_Status__c", "AI_Confidence__c"]),
                 ("Code_Follow_Up__c.AI_Request__c", ["NAME", "Rep_Code_Value__c", "Reason__c", "AI_Status__c", "AI_Confidence__c"])],
        listcols=["NAME", "Purpose__c", "Status__c", "Provider__c", "Item_Count__c", "Duration_Ms__c", "Model_Name__c", "CREATED_DATE"]),
    MR: dict(
        left=[("Name", "Required"), ("Firm__c", "Edit"), ("Status__c", "Required")],
        right=[("Approved_By__c", "Readonly"), ("Approved_At__c", "Readonly"), ("OwnerId", "Edit")],
        related=[],
        listcols=["NAME", "Firm__c", "Status__c", "Approved_By__c", "Approved_At__c"]),
}
EXTRA_P3B = {
    AL: [("Exchange", [("Prompt__c", "Readonly"), ("Response__c", "Readonly"), ("Error_Message__c", "Readonly")])],
    MR: [("Rule", [("Rule__c", "Required")])],
    CF: [("Claude", [("AI_Status__c", "Readonly"), ("AI_Confidence__c", "Readonly"), ("AI_Suggested_Advisor__c", "Readonly"),
                     ("AI_Request__c", "Readonly")])],
    SR: [("Review", [("Reviewer_Decision__c", "Edit"), ("Firm_Override__c", "Edit"), ("Fund_Override__c", "Edit"),
                     ("Remember_Choice__c", "Edit"), ("Assigned_To__c", "Edit"), ("Decided_By__c", "Readonly"), ("Decided_At__c", "Readonly")]),
         ("Claude", [("AI_Status__c", "Readonly"), ("AI_Confidence__c", "Readonly"), ("AI_Suggestion__c", "Readonly"),
                     ("AI_Suggested_Firm__c", "Readonly"), ("AI_Suggested_Fund__c", "Readonly"),
                     ("AI_Suggested_Advisor__c", "Readonly"), ("AI_Request__c", "Readonly")])],
    MP: [("Claude", [("AI_Rationale__c", "Readonly"), ("Proposed_From_Batch__c", "Readonly")])],
}
APEX_CLASSES += ["AiSettings", "ClaudeService", "ClaudeSuggestionService", "ClaudeSuggestionJob", "MappingProposalService",
                 "MappingProposalJob", "ReviewDecisionService", "RosterApprovalService", "MappingActivationService",
                 "MatchingRuleService", "AnthropicApiClient"]

# ================================================================ PHASE 4B.2: headlines, hold, field table, firm follow-up, tokens
field(SR, "AI_Headline__c", "AI Headline", "text",
      "Claude's one-line root cause for the row, naming the person, code, fund or firm involved (for example: Priya Nair - rep code mismatch on 2210). Shown as the row's title in Trade Review; until Claude answers, the app builds one from the match flags. Cleared when the row is re-matched.",
      "Claude's short summary of what is wrong with this row.", length=100)
field(SR, "AI_Recommended_Action__c", "AI Recommended Action", "picklist",
      "The decision Claude recommends: Accept (with the firm and fund it suggests), Reject, or Hold (only the dealer can settle it; see AI Homework). Advisory only; a person always decides.",
      "What Claude recommends doing with this row. You make the final decision.",
      values=["Accept", "Reject", "Hold"], required=False)
field(SR, "AI_Homework__c", "AI Homework", "longtext",
      "When Claude recommends Hold, what needs to be found out from the dealer, worded as a question. Pre-fills the Put on hold dialog and the firm follow-up email.",
      "What Claude suggests asking the dealer before this row can be decided.", length=1000, lines=3)
field(SR, "AI_Field_Suggestions__c", "AI Field Suggestions", "longtext",
      "Claude's per-field answer as JSON: a list of {field, value, confidence, reason}, using record names, never IDs. Written by the system only; the Trade Review app and the AI Suggestion Table component render it as a table.",
      "Claude's suggestion for each field, shown as a table on the page.", length=5000, lines=3)
field(SR, "On_Hold__c", "On Hold", "checkbox",
      "Checked when a reviewer has parked the row until the dealer answers. On-hold rows show on the On Hold tab instead of Needs Decision. Cleared when the row is accepted, rejected or released.",
      "Checked while this row waits for information from the dealer.")
field(SR, "On_Hold_Reason__c", "On Hold Reason", "longtext",
      "The reviewer's homework: what must be found out before the row can be decided. Required to put a row on hold; used as the question in the firm follow-up email. Kept after release for the record.",
      "What needs to be found out before this row can be decided.", length=2000, lines=3)
field(SR, "On_Hold_By__c", "On Hold By", "lookup",
      "The reviewer who put the row on hold. Set by the system.",
      "Who put this row on hold.", ref="User", rel="Held_Staging_Rows", rel_label="Held Staging Rows", required=False)
field(SR, "On_Hold_Since__c", "On Hold Since", "datetime",
      "When the row was put on hold. Set by the system.", "When this row was put on hold.")
field(SR, "Asked_Firm_At__c", "Asked Firm At", "datetime",
      "When the row's question was last sent to the firm's Operations Contact from Trade Review. Drives the 'Asked on' label and the reminder after three days without an answer.",
      "When the dealer was last asked about this row.")
field(CF, "AI_Homework__c", "AI Homework", "longtext",
      "Claude's question for the dealer about this code, used in the firm follow-up email. Written by the system only.",
      "What Claude suggests asking the dealer about this code.", length=1000, lines=3)
field(CF, "AI_Field_Suggestions__c", "AI Field Suggestions", "longtext",
      "Claude's per-field answer as JSON: a list of {field, value, confidence, reason}. Written by the system only; shown as a table in Trade Review and by the AI Suggestion Table component.",
      "Claude's suggestion for each field, shown as a table on the page.", length=5000, lines=3)
field(CF, "Asked_Firm_At__c", "Asked Firm At", "datetime",
      "When this code's question was last sent to the firm's Operations Contact from Trade Review. Drives the 'Asked on' label and the reminder after three days without an answer.",
      "When the dealer was last asked about this code.")
field("Account", "Operations_Contact__c", "Operations Contact", "lookup",
      "The person at this dealer firm who answers rep code and trade questions. Trade Review sends every follow-up email for the firm to this contact, combining its on-hold rows and code reviews in one message.",
      "Choose who at this firm answers trade and rep code questions. Follow-up emails from Trade Review go to this person.",
      ref="Contact", rel="Operations_Contact_For", rel_label="Operations Contact For", required=False)
field(AL, "Input_Tokens__c", "Input Tokens", "number",
      "Tokens sent to the model, as reported by the provider, including any read from or written to the prompt cache. Blank if the provider did not report usage.",
      "How many tokens were sent to Claude.", precision=9, scale=0)
field(AL, "Output_Tokens__c", "Output Tokens", "number",
      "Tokens the model generated, as reported by the provider. Blank if the provider did not report usage.",
      "How many tokens Claude answered with.", precision=9, scale=0)
field(AL, "Cached_Input_Tokens__c", "Cached Input Tokens", "number",
      "Of the input tokens, how many were read from the prompt cache (Anthropic API tier; billed at a fraction of the normal rate). Blank or zero on the Models API, which does not report caching.",
      "How many input tokens were reused from the cache, which costs less.", precision=9, scale=0)
# Phase 4b.3: rows that share an issue are decided together
field(SR, "Issue_Key__c", "Issue Key", "text",
      "What this row's problem has in common with other rows: the dealer, each firm or fund issue and the spelling it is about (plus the rep code when the right answer can differ by code, as for a missing or ambiguous name). Set by matching for rows waiting for review; blank for roster rows, code issues and rows not in review. Trade Review shows rows with the same key as one line with their count and total, and a decision on it applies to all of them. Indexed (External ID, not unique) so the rows sharing a key are found quickly. Keys over 255 characters are stored as a SHA-256 hash.",
      "Rows with the same issue key share the same problem and are decided together in Trade Review. Set by the system.",
      length=255, external_id=True)
# Audit fixes (4b.4): a reviewer's choice of team member for a name that fits more than one of them
field(SR, "Advisor_Override__c", "Advisor Override", "lookup",
      "The team member a reviewer chose to credit when the row's advisor name fits more than one member of a team code (flag ADVISOR_AMBIGUOUS), for example \"Chen\" on a team with Ryan and Megan Chen. Matching credits this advisor 100% if they hold the code on the trade date, and flags the row ADVISOR_FROM_REVIEWER. If left blank on accept, Claude's suggested advisor is used.",
      "Choose which team member to credit when the advisor name on the row fits more than one of them.",
      ref="Contact", rel="Advisor_Override_Staging_Rows", rel_label="Advisor Override Staging Rows", required=False)
for _f in F:
    if _f["obj"] == AL and _f["api"] == "Purpose__c":
        _f["values"] = _f["values"] + ["Firm Follow-up"]
        _f["desc"] = "What the request was for: suggestions on review rows and follow-ups, a proposed mapping profile for an unknown file layout, or a follow-up email to a firm."
EXTRA_P3B[SR][0][1].append(("Issue_Key__c", "Readonly"))
EXTRA_P3B[SR][0][1].insert(3, ("Advisor_Override__c", "Edit"))
EXTRA_P3B[SR].append(("On Hold", [("On_Hold__c", "Readonly"), ("On_Hold_Reason__c", "Edit"), ("On_Hold_By__c", "Readonly"),
                                  ("On_Hold_Since__c", "Readonly"), ("Asked_Firm_At__c", "Readonly")]))
for _name, _items in EXTRA_P3B[SR]:
    if _name == "Claude":
        _items[1:1] = [("AI_Headline__c", "Readonly"), ("AI_Recommended_Action__c", "Readonly"), ("AI_Homework__c", "Readonly")]
for _name, _items in EXTRA_P3B[CF]:
    if _name == "Claude":
        _items += [("AI_Homework__c", "Readonly"), ("Asked_Firm_At__c", "Readonly")]
LAYOUTS_P3B[AL]["right"] += [("Input_Tokens__c", "Readonly"), ("Output_Tokens__c", "Readonly"), ("Cached_Input_Tokens__c", "Readonly")]
LAYOUTS_P3B[AL]["listcols"][-1:-1] = ["Input_Tokens__c", "Output_Tokens__c", "Cached_Input_Tokens__c"]



def field_xml(f):
    k = f["kind"]
    parts = [f"    <fullName>{f['api']}</fullName>"]
    body = {}
    body["description"] = x(f["desc"])
    if f.get("help"):
        body["inlineHelpText"] = x(f["help"])
    body["label"] = x(f["label"])
    req = f.get("required", False)
    if k == "lookup":
        body["deleteConstraint"] = "Restrict" if req else "SetNull"
        body["referenceTo"] = f["ref"]
        body["relationshipLabel"] = x(f["rel_label"])
        body["relationshipName"] = f["rel"]
        body["required"] = "true" if req else "false"
        body["type"] = "Lookup"
    elif k == "md":
        body["referenceTo"] = f["ref"]
        body["relationshipLabel"] = x(f["rel_label"])
        body["relationshipName"] = f["rel"]
        body["relationshipOrder"] = "0"
        body["reparentableMasterDetail"] = "false"
        body["type"] = "MasterDetail"
        body["writeRequiresMasterRead"] = "false"
    elif k == "date":
        body["required"] = "true" if req else "false"
        body["type"] = "Date"
    elif k == "text":
        if f.get("unique"):
            body["caseSensitive"] = "false"
        if f.get("external_id"):
            body["externalId"] = "true"
        body["length"] = str(f["length"])
        body["required"] = "false"
        body["type"] = "Text"
        body["unique"] = "true" if f.get("unique") else "false"
    elif k == "percent":
        body["precision"] = "5"
        body["required"] = "true" if req else "false"
        body["scale"] = "2"
        body["type"] = "Percent"
    elif k == "currency":
        body["precision"] = "18"
        body["required"] = "true" if req else "false"
        body["scale"] = "2"
        body["type"] = "Currency"
    elif k == "formula":
        body["formula"] = x(f["formula"])
        body["formulaTreatBlanksAs"] = "BlankAsZero"
        body["precision"] = "18"
        body["scale"] = "2"
        body["type"] = "Currency"
    elif k == "summary":
        s = f.get("summary", dict(op="sum", summarized="Rep_Code_Assignment__c.Allocation_Percent__c",
                                  fk="Rep_Code_Assignment__c.Rep_Code__c",
                                  filt=("Rep_Code_Assignment__c.Effective_End_Date__c", "equals", "")))
        if s.get("summarized"):
            body["summarizedField"] = s["summarized"]
        fld, op, val = s["filt"]
        body["summaryFilterItems"] = (
            f"\n        <field>{fld}</field>"
            f"\n        <operation>{op}</operation>"
            f"\n        <value>{val}</value>\n    ")
        body["summaryForeignKey"] = s["fk"]
        body["summaryOperation"] = s["op"]
        body["type"] = "Summary"
    elif k == "number":
        body["precision"] = str(f["precision"])
        body["required"] = "false"
        body["scale"] = str(f["scale"])
        body["type"] = "Number"
        body["unique"] = "false"
    elif k == "longtext":
        body["length"] = str(f["length"])
        body["type"] = "LongTextArea"
        body["visibleLines"] = str(f.get("lines", 5))
    elif k == "datetime":
        body["required"] = "false"
        body["type"] = "DateTime"
    elif k == "checkbox":
        body["defaultValue"] = "true" if f.get("default_true") else "false"
        body["type"] = "Checkbox"
    elif k == "picklist":
        body["required"] = "true" if req else "false"
        body["type"] = "Picklist"
        vals = "".join(
            f"\n            <value>\n                <fullName>{x(v)}</fullName>\n                <default>{'true' if v == f.get('default') else 'false'}</default>\n                <label>{x(v)}</label>\n            </value>"
            for v in f["values"])
        body["valueSet"] = (
            "\n        <restricted>true</restricted>"
            "\n        <valueSetDefinition>"
            "\n            <sorted>false</sorted>" + vals +
            "\n        </valueSetDefinition>\n    ")
    for key in sorted(body):
        parts.append(f"    <{key}>{body[key]}</{key}>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            f"<CustomField {NS}>\n" + "\n".join(parts) + "\n</CustomField>\n")


# ---------------------------------------------------------------- validation rules
VRS = [
    ("Rep_Code__c", "Allocation_Cannot_Exceed_100", "Active_Allocation_Total__c > 1", None,
     "Active allocations on this rep code total more than 100%. Reduce or end-date another advisor's share first.",
     "Blocks active assignments on a code from totalling more than 100%. Percent values evaluate as decimals in formulas (100% = 1). Totals under 100 are allowed here and caught at processing time."),
    (A, "End_Date_Before_Start", "AND(NOT(ISBLANK(Effective_End_Date__c)), Effective_End_Date__c < Effective_Start_Date__c)",
     "Effective_End_Date__c", "Effective End Date cannot be before Effective Start Date.",
     "Prevents inverted effective windows, which would break trade-date matching."),
    (A, "Allocation_Percent_Range", "OR(Allocation_Percent__c <= 0, Allocation_Percent__c > 1)",
     "Allocation_Percent__c", "Allocation Percent must be greater than 0 and no more than 100.",
     "Keeps each advisor's share within a valid range."),
    (T, "Fund_Required", "ISBLANK(Fund__c)", "Fund__c",
     "Select the fund that was traded.",
     "Lookups to Product2 cannot be required at the field level, so this rule enforces it."),
    ("Fund_Alias__c", "Fund_Required", "ISBLANK(Fund__c)", "Fund__c",
     "Select the fund this spelling refers to.",
     "Lookups to Product2 cannot be required at the field level, so this rule enforces it."),
    (T, "Amount_Must_Be_Positive", "Amount__c <= 0", "Amount__c",
     "Amount must be a positive number. Use Transaction Type to mark redemptions.",
     "Direction is stored only in Transaction Type, so Amount must always be positive."),
]


def vr_xml(name, formula, disp, msg, desc):
    disp_xml = f"    <errorDisplayField>{disp}</errorDisplayField>\n" if disp else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<ValidationRule {NS}>
    <fullName>{name}</fullName>
    <active>true</active>
    <description>{x(desc)}</description>
    <errorConditionFormula>{x(formula)}</errorConditionFormula>
{disp_xml}    <errorMessage>{x(msg)}</errorMessage>
</ValidationRule>
"""


# ---------------------------------------------------------------- layouts & list views
LAYOUTS = {
    "Rep_Code__c": dict(
        left=[("Name", "Required"), ("Firm__c", "Required")],
        right=[("Active_Allocation_Total__c", "Readonly"), ("OwnerId", "Edit")],
        related=[("Rep_Code_Assignment__c.Rep_Code__c",
                  ["NAME", "Advisor__c", "Allocation_Percent__c", "Effective_Start_Date__c", "Effective_End_Date__c"]),
                 ("Trade__c.Rep_Code__c",
                  ["NAME", "Trade_Date__c", "Fund__c", "Transaction_Type__c", "Amount__c"])],
        listcols=["NAME", "Firm__c", "Active_Allocation_Total__c"]),
    A: dict(
        left=[("Name", "Readonly"), ("Rep_Code__c", "Required"), ("Advisor__c", "Required"),
              ("Allocation_Percent__c", "Required")],
        right=[("Effective_Start_Date__c", "Required"), ("Effective_End_Date__c", "Edit"),
               ("End_Date_Source__c", "Edit"), ("Last_Confirmed_Trade_Date__c", "Edit")],
        related=[],
        listcols=["NAME", "Rep_Code__c", "Advisor__c", "Allocation_Percent__c", "Effective_Start_Date__c",
                  "Effective_End_Date__c", "Last_Confirmed_Trade_Date__c"]),
    T: dict(
        left=[("Name", "Readonly"), ("Rep_Code__c", "Required"), ("Fund__c", "Required"),
              ("Trade_Date__c", "Required")],
        right=[("Transaction_Type__c", "Required"), ("Amount__c", "Required"), ("Signed_Amount__c", "Readonly"),
               ("OwnerId", "Edit")],
        related=[("Trade_Allocation__c.Trade__c",
                  ["NAME", "Advisor__c", "Allocation_Percent__c", "Allocated_Amount__c"])],
        listcols=["NAME", "Trade_Date__c", "Rep_Code__c", "Fund__c", "Transaction_Type__c", "Amount__c",
                  "Signed_Amount__c"]),
    TA: dict(
        left=[("Name", "Readonly"), ("Trade__c", "Required"), ("Advisor__c", "Required")],
        right=[("Allocation_Percent__c", "Required"), ("Allocated_Amount__c", "Required")],
        related=[],
        listcols=["NAME", "Trade__c", "Advisor__c", "Allocation_Percent__c", "Allocated_Amount__c"]),
    "Firm_Alias__c": dict(
        left=[("Name", "Required"), ("Firm__c", "Required")],
        right=[("Normalized_Key__c", "Edit"), ("OwnerId", "Edit")],
        related=[],
        listcols=["NAME", "Normalized_Key__c", "Firm__c"]),
    "Fund_Alias__c": dict(
        left=[("Name", "Required"), ("Fund__c", "Required")],
        right=[("Normalized_Key__c", "Edit"), ("OwnerId", "Edit")],
        related=[],
        listcols=["NAME", "Normalized_Key__c", "Fund__c"]),
}


def items(lst):
    return "".join(
        f"\n            <layoutItems>\n                <behavior>{b}</behavior>\n                <field>{fld}</field>\n            </layoutItems>"
        for fld, b in lst)


def layout_xml(spec, extra=None):
    extra_xml = "".join(f"""
    <layoutSections>
        <customLabel>true</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>true</editHeading>
        <label>{x(label)}</label>
        <layoutColumns>{items(fields_)}
        </layoutColumns>
        <style>OneColumn</style>
    </layoutSections>""" for label, fields_ in (extra or {}).get("sections", []))
    rel = "".join(
        "\n    <relatedLists>" + "".join(f"\n        <fields>{c}</fields>" for c in cols) +
        f"\n        <relatedList>{name}</relatedList>\n    </relatedLists>"
        for name, cols in spec["related"])
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Layout {NS}>
    <layoutSections>
        <customLabel>false</customLabel>
        <detailHeading>false</detailHeading>
        <editHeading>true</editHeading>
        <label>Information</label>
        <layoutColumns>{items(spec['left'])}
        </layoutColumns>
        <layoutColumns>{items(spec['right'])}
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>{extra_xml}
    <layoutSections>
        <customLabel>false</customLabel>
        <detailHeading>true</detailHeading>
        <editHeading>false</editHeading>
        <label>System Information</label>
        <layoutColumns>{items([('CreatedById', 'Readonly')])}
        </layoutColumns>
        <layoutColumns>{items([('LastModifiedById', 'Readonly')])}
        </layoutColumns>
        <style>TwoColumnsTopToBottom</style>
    </layoutSections>{rel}
    <showEmailCheckbox>false</showEmailCheckbox>
    <showHighlightsPanel>false</showHighlightsPanel>
    <showInteractionLogPanel>false</showInteractionLogPanel>
    <showRunAssignmentRulesCheckbox>false</showRunAssignmentRulesCheckbox>
    <showSubmitAndAttachButton>false</showSubmitAndAttachButton>
</Layout>
"""


def listview_xml(cols):
    c = "".join(f"\n    <columns>{col}</columns>" for col in cols)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<ListView {NS}>
    <fullName>All</fullName>{c}
    <filterScope>Everything</filterScope>
    <label>All</label>
</ListView>
"""


# ---------------------------------------------------------------- permission sets
B_ = lambda v: "true" if v else "false"


def permset_xml(label, desc, objects, read_only_objects, classes, standard_read_fields=(), tabs=(), cmts=(), standard_edit_fields=()):
    """objects: {api: (create, read, edit, delete, viewAll, modifyAll)}; custom fields follow object access.
    standard_read_fields: Object.Field standard fields to grant read-only (Name-type fields need no entry)."""
    cas = "".join(f"""
    <classAccesses>
        <apexClass>{c}</apexClass>
        <enabled>true</enabled>
    </classAccesses>""" for c in sorted(classes))
    fps = []
    for f in sorted(F, key=lambda f: (f["obj"], f["api"])):
        if f["obj"] not in objects or f["kind"] == "md" or f.get("required"):
            continue  # required and master-detail fields cannot carry field permissions
        editable = f["kind"] not in ("formula", "summary") and f["obj"] not in read_only_objects
        fps.append(f"""
    <fieldPermissions>
        <editable>{B_(editable)}</editable>
        <field>{f['obj']}.{f['api']}</field>
        <readable>true</readable>
    </fieldPermissions>""")
    for sf in standard_read_fields:
        fps.append(f"""
    <fieldPermissions>
        <editable>false</editable>
        <field>{sf}</field>
        <readable>true</readable>
    </fieldPermissions>""")
    for sf in standard_edit_fields:
        fps.append(f"""
    <fieldPermissions>
        <editable>true</editable>
        <field>{sf}</field>
        <readable>true</readable>
    </fieldPermissions>""")
    ops = "".join(f"""
    <objectPermissions>
        <allowCreate>{B_(c)}</allowCreate>
        <allowDelete>{B_(d)}</allowDelete>
        <allowEdit>{B_(e)}</allowEdit>
        <allowRead>{B_(r)}</allowRead>
        <modifyAllRecords>{B_(ma)}</modifyAllRecords>
        <object>{o}</object>
        <viewAllRecords>{B_(va)}</viewAllRecords>
    </objectPermissions>""" for o, (c, r, e, d, va, ma) in sorted(objects.items()))
    tss = "".join(f"""
    <tabSettings>
        <tab>{t}</tab>
        <visibility>Visible</visibility>
    </tabSettings>""" for t in sorted(tabs))
    cms = "".join(f"""
    <customMetadataTypeAccesses>
        <enabled>true</enabled>
        <name>{m}</name>
    </customMetadataTypeAccesses>""" for m in sorted(cmts))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet {NS}>{cas}{cms}
    <description>{x(desc)}</description>{''.join(fps)}
    <hasActivationRequired>false</hasActivationRequired>
    <label>{x(label)}</label>{ops}{tss}
</PermissionSet>
"""


# ---------------------------------------------------------------- write
LAYOUTS.update(LAYOUTS_P2)
LAYOUTS.update(LAYOUTS_P3)
LAYOUTS.update(LAYOUTS_P3B)
EXTRA_LAYOUT_ITEMS[SR] = dict(sections=[("Details", [("Validation_Errors__c", "Readonly"), ("Match_Notes__c", "Readonly"),
                                                     ("Match_Candidates__c", "Readonly"), ("Raw_Data__c", "Readonly")])])
for obj_, secs in EXTRA_P3B.items():
    EXTRA_LAYOUT_ITEMS.setdefault(obj_, dict(sections=[]))["sections"].extend(secs)
LAYOUTS[IB]["right"].append(("Header_Fingerprint__c", "Readonly"))
VRS.extend(VRS_P2)
VRS.extend(VRS_P3B)
for api, o in OBJECTS.items():
    w(f"objects/{api}/{api}.object-meta.xml", object_xml(o))
    w(f"objects/{api}/listViews/All.listView-meta.xml", listview_xml(LAYOUTS[api]["listcols"]))
    w(f"layouts/{api}-{o['label']} Layout.layout-meta.xml", layout_xml(LAYOUTS[api], EXTRA_LAYOUT_ITEMS.get(api)))
for f in F:
    w(f"objects/{f['obj']}/fields/{f['api']}.field-meta.xml", field_xml(f))
for obj, name, formula, disp, msg, desc in VRS:
    w(f"objects/{obj}/validationRules/{name}.validationRule-meta.xml", vr_xml(name, formula, disp, msg, desc))

# Object tabs (phase 3A: the follow-up to-do list must be reachable from the App Launcher for the demo).
TABS = {"Code_Follow_Up__c": "Custom53: Bell", AL: "Custom63: Chip", MR: "Custom90: Scales",
        IB: "Custom13: Box", SR: "Custom18: Form", MP: "Custom78: Map"}
# Phase 3B: the reviewer's work queue until the review LWC (phase 4) exists.
w(f"objects/{SR}/listViews/Needs_Review.listView-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<ListView {NS}>
    <fullName>Needs_Review</fullName>
    <columns>NAME</columns>
    <columns>Import_Batch__c</columns>
    <columns>Row_Type__c</columns>
    <columns>Source_Firm_Name__c</columns>
    <columns>Source_Advisor_Name__c</columns>
    <columns>Source_Fund_Name__c</columns>
    <columns>Match_Flags__c</columns>
    <columns>AI_Status__c</columns>
    <columns>AI_Confidence__c</columns>
    <filterScope>Everything</filterScope>
    <filters>
        <field>Match_Status__c</field>
        <operation>equals</operation>
        <value>Needs Review</value>
    </filters>
    <label>Needs Review</label>
</ListView>
""")
for t, motif in TABS.items():
    w(f"tabs/{t}.tab-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomTab {NS}>
    <customObject>true</customObject>
    <motif>{motif}</motif>
</CustomTab>
""")
# Custom metadata: Claude settings. Deployable configuration, readable without SOQL (getInstance).
CMT = "Trade_AI_Setting__mdt"
w(f"objects/{CMT}/{CMT}.object-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomObject {NS}>
    <description>Settings for Claude suggestions: on or off, provider (Models API or Anthropic API), models and limits. One record, Default, is read by AiSettings.</description>
    <label>Trade AI Setting</label>
    <pluralLabel>Trade AI Settings</pluralLabel>
    <visibility>Public</visibility>
</CustomObject>
""")
CMT_FIELDS = [
    ("Enabled__c", "Enabled", "Checkbox", "When unchecked, no Claude requests are made; matching and review work without suggestions.", "Turn Claude suggestions on or off."),
    ("Provider__c", "Provider", "Picklist", "How Claude is reached. Models API (default, Enterprise tier): through the Einstein Trust Layer, needs Einstein generative AI. Anthropic API (Standard tier): directly to Anthropic with the firm's own API key, which must be stored in the Anthropic API external credential. Changes are recorded in Setup Audit Trail and on every AI Request Log.", "Models API keeps requests inside the Einstein Trust Layer. Choose Anthropic API only if your compliance team has approved sending data directly to Anthropic."),
    ("Model_Name__c", "Model Name", "Text", "Models API model API name, used when Provider is Models API, for example sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet. Changing models needs no code change.", "The Models API name of the Claude model to use."),
    ("Anthropic_Model__c", "Anthropic Model", "Text", "Anthropic model ID, used when Provider is Anthropic API, for example claude-sonnet-5-5. Changing models needs no code change.", "The Anthropic model ID to use with the Anthropic API."),
    ("Max_Items_Per_Request__c", "Max Items Per Request", "Number", "How many rows and follow-ups go into one Claude request. Larger requests are cheaper per item but slower.", "Items per Claude request, for example 10."),
    ("Require_Two_Person_Rule_Approval__c", "Require Two-Person Rule Approval", "Checkbox", "When checked, a Matching Rule must be activated by someone other than its author.", "Require a second person to activate matching rules."),
]
for api, label, typ, desc, help_ in CMT_FIELDS:
    extra = {"Checkbox": "    <defaultValue>false</defaultValue>\n", "Text": "    <length>255</length>\n    <required>false</required>\n",
             "Number": "    <precision>3</precision>\n    <required>false</required>\n    <scale>0</scale>\n",
             "Picklist": """    <required>false</required>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value>
                <fullName>Models API</fullName>
                <default>true</default>
                <label>Models API</label>
            </value>
            <value>
                <fullName>Anthropic API</fullName>
                <default>false</default>
                <label>Anthropic API</label>
            </value>
        </valueSetDefinition>
    </valueSet>
"""}[typ]
    w(f"objects/{CMT}/fields/{api}.field-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomField {NS}>
    <fullName>{api}</fullName>
{extra}    <description>{x(desc)}</description>
    <externalId>false</externalId>
    <fieldManageability>DeveloperControlled</fieldManageability>
    <inlineHelpText>{x(help_)}</inlineHelpText>
    <label>{x(label)}</label>
    <type>{typ}</type>
</CustomField>
""")
CMT_VALUES = [("Anthropic_Model__c", "string", "claude-sonnet-5-5"),
              ("Enabled__c", "boolean", "true"), ("Max_Items_Per_Request__c", "double", "10"),
              ("Model_Name__c", "string", "sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet"),
              ("Provider__c", "string", "Models API"),
              ("Require_Two_Person_Rule_Approval__c", "boolean", "true")]
vals = "".join(f"""
    <values>
        <field>{f_}</field>
        <value xsi:type="xsd:{t_}">{v_}</value>
    </values>""" for f_, t_, v_ in CMT_VALUES)
w("customMetadata/Trade_AI_Setting.Default.md-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata {NS} xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>Default</label>
    <protected>false</protected>{vals}
</CustomMetadata>
""")
FULL = (True, True, True, True, True, True)
w("permissionsets/Trade_Import_Admin.permissionset-meta.xml", permset_xml(
    "Trade Import Admin",
    "Full access to the trade import data model, ingestion objects and Apex. For admins and the demo user.",
    {o: FULL for o in OBJECTS}, set(), APEX_CLASSES, tabs=list(TABS) + ["Trade_Review"], cmts=[CMT],
    standard_edit_fields=["Account.Operations_Contact__c"]))
# Least privilege for the push job's integration user: create batches and staging rows, read profiles.
w("permissionsets/Trade_Import_Integration.permissionset-meta.xml", permset_xml(
    "Trade Import Integration",
    "Least privilege for the push job and its background jobs: ingest files, stage and match rows, raise follow-ups, read reference data, log Claude requests and save Draft mapping proposals.",
    {IB: (True, True, True, False, False, False),
     SR: (True, True, True, False, False, False),
     MP: (True, True, False, False, False, False),  # create only: Claude's proposals are inserted as Draft
     AL: (True, True, False, False, False, False),  # create only: the AI audit log is never edited
     MR: (False, True, False, False, False, False),
     "Rep_Code__c": (False, True, False, False, False, False),
     "Rep_Code_Assignment__c": (False, True, False, False, False, False),
     "Firm_Alias__c": (False, True, False, False, False, False),
     "Fund_Alias__c": (False, True, False, False, False, False),
     CF: (True, True, True, False, False, False),
     # Matching runs in the queued job as this user and reads firms, branches, advisors and funds in user mode.
     "Account": (False, True, False, False, False, False),
     "Contact": (False, True, False, False, False, False),
     "Product2": (False, True, False, False, False, False)},
    {MR, "Rep_Code__c", "Rep_Code_Assignment__c", "Firm_Alias__c", "Fund_Alias__c", "Account", "Contact", "Product2"},
    ["TradeIngestResource"], standard_read_fields=["Account.ParentId", "Contact.AccountId"], cmts=[CMT]))
# Phase 4b: the Trade Review app as its own tab, and a permission set for reviewers who are not admins.
w("tabs/Trade_Review.tab-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<CustomTab {NS}>
    <description>The Trade Review app: work queue, Claude's suggestions, decisions, follow-ups, new file layouts and file upload.</description>
    <label>Trade Review</label>
    <lwcComponent>tradeReview</lwcComponent>
    <motif>Custom90: Scales</motif>
</CustomTab>
""")
CRE = (True, True, True, False, False, False)
CR = (True, True, False, False, False, False)
R_ = (False, True, False, False, False, False)
# A reviewer's actions start background work that runs as the reviewer: staging an uploaded file, re-matching,
# applying roster rows (new advisors, codes and assignments), raising follow-ups, asking Claude, saving Claude's
# mapping proposals. So a reviewer needs the same data access as the integration user plus the roster writes.
w("permissionsets/Trade_Import_Reviewer.permissionset-meta.xml", permset_xml(
    "Trade Import Reviewer",
    "For people who work the Trade Review queue: decide rows, approve rosters, work follow-ups, upload files and activate mappings. Grants the data access the background work they start needs. Claude calls also need the org's generative AI permission.",
    {IB: CRE, SR: CRE, CF: CRE, MP: CRE, AL: CR, MR: CRE,
     "Rep_Code__c": CRE, "Rep_Code_Assignment__c": CRE,
     "Firm_Alias__c": CR, "Fund_Alias__c": CR,
     "Account": R_, "Contact": CR, "Product2": R_},
    {"Account", "Product2"},
    ["ReviewController"], standard_read_fields=["Account.ParentId", "Contact.Email"], standard_edit_fields=["Contact.AccountId"],
    tabs=list(TABS) + ["Trade_Review"], cmts=[CMT]))

# Phase 4a, Standard tier. Kept apart from everything else so an Enterprise install can leave it out entirely:
# no Apex refers to these components at compile time (only the callout:Anthropic_API endpoint string).
# The API key itself is never in metadata: an admin enters it on the principal in Setup.
w("externalCredentials/Anthropic_API.externalCredential-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<ExternalCredential {NS}>
    <authenticationProtocol>Custom</authenticationProtocol>
    <description>Holds the firm's Anthropic API key for the Standard tier and sends it as the x-api-key header. Enter the key as the ApiKey authentication parameter on the Anthropic principal in Setup; it is never stored in metadata or code.</description>
    <externalCredentialParameters>
        <parameterGroup>DefaultGroup</parameterGroup>
        <parameterName>x-api-key</parameterName>
        <parameterType>AuthHeader</parameterType>
        <parameterValue>{{!$Credential.Anthropic_API.ApiKey}}</parameterValue>
        <sequenceNumber>1</sequenceNumber>
    </externalCredentialParameters>
    <externalCredentialParameters>
        <parameterGroup>Anthropic</parameterGroup>
        <parameterName>Anthropic</parameterName>
        <parameterType>NamedPrincipal</parameterType>
        <sequenceNumber>1</sequenceNumber>
    </externalCredentialParameters>
    <label>Anthropic API</label>
</ExternalCredential>
""")
w("namedCredentials/Anthropic_API.namedCredential-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<NamedCredential {NS}>
    <allowMergeFieldsInBody>false</allowMergeFieldsInBody>
    <allowMergeFieldsInHeader>false</allowMergeFieldsInHeader>
    <calloutStatus>Enabled</calloutStatus>
    <description>Standard tier: the Anthropic Messages API, authenticated by the Anthropic API external credential. Used only when Trade AI Setting Provider is Anthropic API.</description>
    <generateAuthorizationHeader>false</generateAuthorizationHeader>
    <label>Anthropic API</label>
    <namedCredentialParameters>
        <parameterName>Url</parameterName>
        <parameterType>Url</parameterType>
        <parameterValue>https://api.anthropic.com</parameterValue>
    </namedCredentialParameters>
    <namedCredentialParameters>
        <externalCredential>Anthropic_API</externalCredential>
        <parameterName>ExternalCredential</parameterName>
        <parameterType>Authentication</parameterType>
    </namedCredentialParameters>
    <namedCredentialType>SecuredEndpoint</namedCredentialType>
</NamedCredential>
""")
w("permissionsets/Trade_Import_Anthropic_API.permissionset-meta.xml", f"""<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet {NS}>
    <description>Standard tier only: lets a user's background jobs call the Anthropic API through the Anthropic API credential. Assign to the users who run imports. Never assign in an Enterprise-tier org.</description>
    <externalCredentialPrincipalAccesses>
        <enabled>true</enabled>
        <externalCredentialPrincipal>Anthropic_API-Anthropic</externalCredentialPrincipal>
    </externalCredentialPrincipalAccesses>
    <hasActivationRequired>false</hasActivationRequired>
    <label>Trade Import Anthropic API</label>
    <objectPermissions>
        <allowCreate>false</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>false</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>UserExternalCredential</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
</PermissionSet>
""")
print(f"objects={len(OBJECTS)} fields={len(F)} vrs={len(VRS)}")
