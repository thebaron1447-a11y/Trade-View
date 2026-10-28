"""Phase 3A sample data: one definition produces
   - the data lake sample files (trade + AUM mixed, plus a roster file),
   - the mapping profile seed script (upsert by name),
   - a Python simulation of ingestion + matching against the phase 1 seed world,
   - DemoScenarioTest.cls, which runs the same files through the real Apex and asserts the simulated outcomes."""
import csv, io, json, os, runpy, sys
from datetime import date
from decimal import Decimal
sys.path.insert(0, os.path.dirname(__file__))
import port
from gen_tests import apex_str

BUILD = "/home/claude/build"
APEX = "/home/claude/apex"
NNBSP = " "

# ---------------------------------------------------------------- world (phase 1 seed, as deployed)
cwd = os.getcwd()
os.chdir("/home/claude")
seed = runpy.run_path("/home/claude/gen_seed.py", run_name="seed_import")
os.chdir(cwd)
ref = lambda v: v[1:] if isinstance(v, str) and v.startswith("@") else v
d = lambda s: date.fromisoformat(s) if s else None

FIRM_NAMES = {r["attributes"]["referenceId"]: r["Name"] for r in seed["firms"]}
ACCOUNT_NAMES = dict(FIRM_NAMES)
ACCOUNT_PARENT = {}
for r in seed["branches"]:
    ACCOUNT_NAMES[r["attributes"]["referenceId"]] = r["Name"]
    ACCOUNT_PARENT[r["attributes"]["referenceId"]] = ref(r["ParentId"])
CONTACTS = {r["attributes"]["referenceId"]: dict(first=r["FirstName"], last=r["LastName"], account=ref(r["AccountId"]))
            for r in seed["contacts"]}
FUND_NAMES = {r["attributes"]["referenceId"]: r["Name"] for r in seed["products"]}
REP_CODES = [dict(ref=r["attributes"]["referenceId"], name=r["Name"], firm=ref(r["Firm__c"])) for r in seed["rep_codes"]]
ASSIGNMENTS = [dict(ref=r["attributes"]["referenceId"], code=ref(r["Rep_Code__c"]), advisor=ref(r["Advisor__c"]),
                    pct=Decimal(str(r["Allocation_Percent__c"])), start=d(r["Effective_Start_Date__c"]),
                    end=d(r.get("Effective_End_Date__c")), last=d(r.get("Last_Confirmed_Trade_Date__c")),
                    src=r.get("End_Date_Source__c"))
               for r in seed["assignments"]]
FIRM_ALIASES = [(seed["key"](n), f) for n, f in seed["firm_alias_src"]]
FUND_ALIASES = [(seed["key"](n), f) for n, f in seed["fund_alias_src"]]


def world(assignments=ASSIGNMENTS, contacts=CONTACTS):
    return port.World(FIRM_ALIASES, FUND_ALIASES, REP_CODES, assignments, contacts, ACCOUNT_PARENT)


# ---------------------------------------------------------------- profiles
PROFILES = [
    dict(code="BARDER", name="Barder - trade export", firm="FirmBarder", single=True, feed="Trade Activity", aum="AUM",
         headers=["Trade Dt", "Dealer Rep #", "Advisor", "Dealer Name", "Fund Description", "Record Type", "Gross Amt"],
         cmap={"Trade Dt": "tradeDate", "Dealer Rep #": "repCode", "Advisor": "advisorName", "Dealer Name": "firmName",
               "Fund Description": "fundName", "Record Type": "rowType", "Gross Amt": "amount"},
         date="MM/DD/YYYY", sep="Period", conv="Signed Amount"),
    dict(code="NORTHGATE", name="Northgate - IA transactions", firm="FirmNorthgate", single=True, feed="Trade Activity",
         aum="POSITION",
         headers=["IA Code", "Rep Name", "Firm", "Branch", "Product", "Txn Type", "Trade Date", "Amount"],
         cmap={"IA Code": "repCode", "Rep Name": "advisorName", "Firm": "firmName", "Branch": "branchName",
               "Product": "fundName", "Txn Type": "transactionType", "Trade Date": "tradeDate", "Amount": "amount"},
         date="DD/MM/YYYY", sep="Period", conv="Type Column"),
    dict(code="LUMIERE", name="Lumière - relevé des transactions", firm="FirmLumiere", single=True, feed="Trade Activity",
         aum="SOLDE",
         headers=["Date de transaction", "Code représentant", "Nom du conseiller", "Courtier", "Fonds", "Type", "Montant"],
         cmap={"Date de transaction": "tradeDate", "Code représentant": "repCode", "Nom du conseiller": "advisorName",
               "Courtier": "firmName", "Fonds": "fundName", "Type": "transactionType", "Montant": "amount"},
         date="YYYY-MM-DD", sep="Comma", conv="Type Column"),
    dict(code="BARDER", name="Barder - advisor code roster", firm="FirmBarder", single=True, feed="Advisor Code Roster",
         aum=None,
         headers=["Rep Code", "Advisor Name", "Branch", "Effective Date"],
         cmap={"Rep Code": "repCode", "Advisor Name": "advisorName", "Branch": "branchName", "Effective Date": "tradeDate"},
         date="MM/DD/YYYY", sep="Period", conv="Type Column"),
]

# ---------------------------------------------------------------- files (trap noted per row)
FILES = [
    dict(code="BARDER", folder="inbox", name="barder_trades_2026-10-05.csv", delim=",", eol="\r\n", bom=True, rows=[
        ["09/02/2026", "0457", "Julia Morales", "Barder and Co", "Wealth World Fund A", "TRADE", "$400,000.00"],   # leading zero; firm variant
        ["09/03/2026", "0457", "J. Morales", "Barder and C.", "WEALTH WORLD FD SER A", "TRADE", "-$150,000.00"],  # initial; redemption by sign
        ["09/08/2026", "2210", "Marcus Bell", "Barder & Company", "Cdn Dividend Fund A", "TRADE", "$75,000.00"],
        ["09/22/2026", "2210", "Priya Nair", "Barder and Co", "Wealth World ETF", "TRADE", "$220,000.00"],      # silent reassignment
        ["09/24/2026", "2210", "P. Nair", "", "Wealth World ETF", "TRADE", "$60,000.00"],                       # same; blank firm filled
        ["09/25/2026", "0457", "Julia Morales", "Barder and Co", "ETF Wealth World Fund A", "TRADE", "$12,500.00"],  # ambiguous fund
        ["09/25/2026", "0457", "Julia Morales", "Barder and Co", "Canadian Dividend Fund, Series A", "TRADE", "$8,000.00"],  # quoted comma
        ["09/26/2026", "0457", "Julia Morales", "Barder and Co", "Wealth World Fund A", "TRADE", ""],          # error: no amount
        ["09/27/2026", "3390", "Hannah Pierce", "Barder and Co", "Wealth World Fund A", "TRADE", "$45,000.00"],  # unknown code
        ["09/30/2026", "0457", "Julia Morales", "Barder and Co", "", "AUM", "$1,850,000.00"],                   # AUM row
        ["03/10/2024", "0457", "Julia Morales", "Barder and Co", "Wealth World Fund A", "TRADE", "$5,000.00"],  # dated before 457 started
        ["09/29/2026", "0457", "Julia Morales", "Barder and Co", "Wealth World Fund", "TRADE", "$9,500.00"],    # fund could be A or F
    ]),
    dict(code="NORTHGATE", folder="inbox", name="northgate_trades_2026-10-05.csv", delim=",", eol="\n", bom=False, rows=[
        ["8800", "Aisha Khan", "Northgate WP", "Toronto", "Wealth World Fund - Series F", "BUY", "13/09/2026", "250000"],  # one team member named
        ["8800", "Daniel Okafor", "Northgate WP", "Toronto", "Global Bond Fund - Series F", "SELL", "03/09/2026", "40000"],
        ["5521", "Tom Reilly", "", "Toronto", "Canadian Dividend Fund - Series A", "BUY", "18/09/2026", "90000"],  # dormant, name confirms
        ["3102", "Julia Morales", "Northgate Wealth Partners Inc.", "Toronto", "Wealth World Fund - Series A", "Buy", "15/05/2024", "30000"],  # historical
        ["8800", "", "Northgate WP", "Toronto", "Wealth World Fund - Series A", "P", "20/09/2026", "1,200,000"],  # team split, only 80% active
        ["8800", "Aisha Khan", "Northgate WP", "Toronto", "Wealth World ETF", "SELL", "31/09/2026", "15000"],    # error: no 31 Sept
        ["5521", "Tom Reilly", "Northgate WP", "Toronto", "Wealth World ETF", "SWITCH", "21/09/2026", "5000"],   # error: not buy/sell
        ["3102", "", "Northgate WP", "Toronto", "Wealth World Fund - Series F", "BUY", "10/09/2026", "55000"],   # old code, ended
        ["5521", "", "Northgate WP", "Toronto", "Wealth World ETF", "BUY", "22/09/2026", "18000"],              # dormant, no name
        ["8800", "", "Northgate WP", "Toronto", "", "POSITION", "30/09/2026", "9800000"],                        # AUM on incomplete team
        ["5521", "Tom Reilly", "Northgate WP", "Toronto", "", "POSITION", "30/09/2026", "640000"],               # AUM, dormant, named
        ["8800", "Aisha Khan", "Northgate Securities Ltd", "Toronto", "Wealth World ETF", "BUY", "24/09/2026", "32000"],  # unknown firm name
    ]),
    dict(code="LUMIERE", folder="inbox", name="lumiere_transactions_2026-10-05.csv", delim=";", eol="\r\n", bom=True, rows=[
        ["2026-09-10", "7700", "Élise Gagnon", "Lumiere Valeurs Mobilieres", "Wealth World Fund - Series A", "ACHAT", f"125{NNBSP}000,00"],
        ["2026-09-12", "7700", "Marc-André Roy", "Lumiere Valeurs Mobilieres", "Global Bond Fund - Series F", "RACHAT", f"48{NNBSP}500,50"],
        ["2026-09-15", "7700", "Élise Gagnon et Marc-André Roy", "Lumière Valeurs Mobilières Ltée", "Wealth World ETF", "Achat", "10 000,00"],
        ["2026-09-19", "7700", "", "", "Canadian Dividend Fund - Series A", "ACHAT", "7 250,75"],
        ["2026-09-30", "7700", "", "", "", "SOLDE", f"3{NNBSP}400{NNBSP}000,00"],
        ["2026-09-26", "7700", "Sophie Tremblay", "Lumiere Valeurs Mobilieres", "Wealth World ETF", "ACHAT", "22 000,00"],  # not on the team
    ]),
    dict(code="KESTREL", folder="inbox", name="kestrel_export_2026-10-05.csv", delim=",", eol="\r\n", bom=False,
         headers=["Representative", "Rep No.", "Organisation", "Security Name", "Settle Date", "Side", "Value"], rows=[
        ["Ryan Chen", "1001", "Kestrel Capital", "Wealth World Fund - Series A", "2026-09-29", "B", "50,000.00"],
        ["Megan Chen", "1001", "Kestrel Capital", "Global Bond Fund - Series F", "2026-09-30", "S", "20,000.00"],
        ["Ryan Chen", "1001", "", "Wealth World ETF", "2026-10-01", "B", "5,000.00"],                            # no firm name at all
    ]),
    dict(code="BARDER", folder="roster", name="barder_advisor_codes_2026-10-05.csv", delim=",", eol="\r\n", bom=False,
         profile="Barder - advisor code roster", rows=[
        ["457", "Julia Morales", "Barder & Company - Oakville", "06/15/2024"],
        ["2210", "Priya Nair", "Barder & Company - Hamilton", "09/15/2026"],
        ["3390", "Hannah Pierce", "Barder & Company - Oakville", "09/20/2026"],
    ]),
]

# What the design says should happen (checked against the simulation, so the port is held to intent).
INTENT = {
    ("BARDER", 1): ("Matched", None), ("BARDER", 2): ("Matched", None), ("BARDER", 3): ("Matched", None),
    ("BARDER", 4): ("Held", "Reassignment Suspected"), ("BARDER", 5): ("Held", "Reassignment Suspected"),
    ("BARDER", 6): ("Needs Review", None), ("BARDER", 7): ("Matched", None), ("BARDER", 8): ("Invalid", None),
    ("BARDER", 9): ("Held", "Unknown Code"), ("BARDER", 10): ("Matched", None),
    ("BARDER", 11): ("Needs Review", None), ("BARDER", 12): ("Needs Review", None),
    ("NORTHGATE", 1): ("Matched", None), ("NORTHGATE", 2): ("Matched", None), ("NORTHGATE", 3): ("Matched", None),
    ("NORTHGATE", 4): ("Matched", None), ("NORTHGATE", 5): ("Held", "Allocation Incomplete"),
    ("NORTHGATE", 6): ("Invalid", None), ("NORTHGATE", 7): ("Invalid", None),
    ("NORTHGATE", 8): ("Held", "Code Ended"), ("NORTHGATE", 9): ("Held", "Code Dormant"),
    ("NORTHGATE", 10): ("Held", "Allocation Incomplete"), ("NORTHGATE", 11): ("Matched", None),
    ("NORTHGATE", 12): ("Needs Review", None),
    ("LUMIERE", 1): ("Matched", None), ("LUMIERE", 2): ("Matched", None), ("LUMIERE", 3): ("Matched", None),
    ("LUMIERE", 4): ("Matched", None), ("LUMIERE", 5): ("Matched", None),
    ("LUMIERE", 6): ("Held", "Reassignment Suspected"),
    ("ROSTER", 1): ("Matched", None), ("ROSTER", 2): ("Needs Review", None), ("ROSTER", 3): ("Needs Review", None),
}


def to_csv(headers, rows, delim, eol, bom):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=delim, lineterminator=eol, quoting=csv.QUOTE_MINIMAL)
    w.writerow(headers)
    w.writerows(rows)
    return ("﻿" if bom else "") + buf.getvalue()


def profile_for(f):
    if f.get("profile"):
        return next(p for p in PROFILES if p["name"] == f["profile"])
    return next((p for p in PROFILES if p["code"] == f["code"] and p["feed"] == "Trade Activity"), None)


def cfg_for(p):
    return dict(dateFormat=p["date"], decimalSeparator=p["sep"], direction=p["conv"],
                fallbackFirm=FIRM_NAMES[p["firm"]] if p["single"] else None,
                roster=p["feed"] == "Advisor Code Roster",
                aum={port.indicator_key(v) for v in (p["aum"] or "").split(",") if port.indicator_key(v)})


def contact_name(cref, contacts=CONTACTS):
    c = contacts[cref]
    return (c["first"] + " " + c["last"]).strip()


def simulate(f, w):
    """Returns (batch status, rows[]) for one file, mirroring ImportBatchProcessor + TradeMatcher."""
    text = to_csv(f.get("headers") or profile_for(f)["headers"], f["rows"], f["delim"], f["eol"], f["bom"])
    rows = port.parse_csv(text, port.detect_delimiter(text))
    headers, data = rows[0], rows[1:]
    fp = port.fingerprint(headers)
    prof = next((p for p in PROFILES if port.fingerprint(p["headers"]) == fp), None)
    if prof is None:
        return "Mapping Review", [], text
    cols, problems = port.resolve_columns3(headers, prof["cmap"], prof)
    assert not problems, problems
    out = []
    for i, r in enumerate(data):
        n = port.normalize_row3(headers, r, cols, cfg_for(prof), i + 1)
        if n["status"] == "Invalid":
            n.update(match=dict(status="Invalid", reason=None, firm=None, code=None, fund=None, credited=None), flags=[])
        else:
            m, flags = port.match_row(n, w)
            n.update(match=m, flags=flags)
        out.append(n)
    return "Pending Review", out, text


def follow_ups(results):
    """key -> [count, held trade amount]"""
    fu = {}
    for code, rows in results:
        for r in rows:
            m = r["match"]
            if m["status"] == "Held":
                k = f"{code}|{r['repCode']}|{m['reason']}"
                fu.setdefault(k, [0, Decimal("0")])
                fu[k][0] += 1
                if r["rowType"] == "Trade":
                    fu[k][1] += r["amount"]
    return fu


# ---------------------------------------------------------------- run simulation
W = world()
sims = {}
problems = []
for f in FILES:
    label = "ROSTER" if f["folder"] == "roster" else f["code"]
    status, rows, text = simulate(f, W)
    sims[label] = (f, status, rows, text)
    for r in rows:
        want = INTENT.get((label, r["row"]))
        got = (r["match"]["status"], r["match"]["reason"])
        if want != got:
            problems.append(f"{label} row {r['row']}: intent {want}, simulated {got} flags={r['flags']}")
trade_results = [(c, sims[c][2]) for c in ("BARDER", "NORTHGATE", "LUMIERE")]
FU = follow_ups(trade_results)
expected_fu = {"BARDER|2210|Reassignment Suspected": [2, Decimal("280000.00")],
               "BARDER|3390|Unknown Code": [1, Decimal("45000.00")],
               "NORTHGATE|8800|Allocation Incomplete": [2, Decimal("1200000.00")],
               "NORTHGATE|3102|Code Ended": [1, Decimal("55000.00")],
               "NORTHGATE|5521|Code Dormant": [1, Decimal("18000.00")],
               "LUMIERE|7700|Reassignment Suspected": [1, Decimal("22000.00")]}
# Flags the new phase 4b rows exist to show (one per problem type not covered before).
EXPECTED_FLAGS = {("BARDER", 11): ["DATE_BEFORE_CODE_START"], ("BARDER", 12): ["FUND_AMBIGUOUS"],
                  ("NORTHGATE", 12): ["FIRM_UNRESOLVED"], ("LUMIERE", 6): ["TEAM_CHANGE_SUSPECTED"]}
if FU != expected_fu:
    problems.append(f"follow-ups: {FU}")
for (label, n), want_flags in EXPECTED_FLAGS.items():
    got_flags = next(r["flags"] for r in sims[label][2] if r["row"] == n)
    if got_flags != want_flags:
        problems.append(f"{label} row {n}: flags {got_flags}, want {want_flags}")

# Resolution scenario: the firm confirms Priya Nair took over 2210 on 2026-09-15.
contacts_after = dict(CONTACTS)
contacts_after["AdvPriya"] = dict(first="Priya", last="Nair", account="BrBarderHam")
assign_after = [dict(a, end=date(2026, 9, 14), src="Confirmed by Firm") if a["ref"] == "AsMarcus2210" else a for a in ASSIGNMENTS]
assign_after.append(dict(ref="AsPriya2210", code="RcBarder2210", advisor="AdvPriya", pct=Decimal("100"),
                         start=date(2026, 9, 15), end=None, last=None, src=None))
W2 = world(assign_after, contacts_after)
resolved = {}
for r in sims["BARDER"][2]:
    if r["match"]["reason"] == "Reassignment Suspected":
        m, flags = port.match_row(r, W2)
        resolved[r["row"]] = (m, flags)
        if m["status"] != "Matched" or contact_name(m["credited"], contacts_after) != "Priya Nair":
            problems.append(f"resolution row {r['row']}: {m} {flags}")

for label, (f, status, rows, _) in sims.items():
    print(f"{label:9} {status:14} " + "  ".join(
        f"{r['row']}:{r['match']['status'][:4]}" + (f"[{r['match']['reason']}]" if r['match']['reason'] else "") for r in rows))
print("follow-ups:", {k: [v[0], str(v[1])] for k, v in FU.items()})
if problems:
    print("PROBLEMS:\n" + "\n".join(problems))
    sys.exit(1)
print("simulation matches design intent (all rows, follow-ups, resolution)")

# ---------------------------------------------------------------- write sample files
for f in FILES:
    label = "ROSTER" if f["folder"] == "roster" else f["code"]
    path = f"{BUILD}/datalake/samples/{f['folder']}/{f['code']}/{f['name']}"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(sims[label][3])

# File-level problems (phase 4b): the same Barder file sent twice under another name (recognised by its contents and
# not loaded again), and a Northgate file damaged in transit (an unclosed quote: the batch fails and stages nothing).
with open(f"{BUILD}/datalake/samples/inbox/BARDER/barder_trades_2026-10-05_resent.csv", "w", encoding="utf-8", newline="") as fh:
    fh.write(sims["BARDER"][3])
_ng = next(p for p in PROFILES if p["code"] == "NORTHGATE")
with open(f"{BUILD}/datalake/samples/inbox/NORTHGATE/northgate_trades_2026-10-06.csv", "w", encoding="utf-8", newline="") as fh:
    fh.write(",".join(_ng["headers"]) + "\n" + '8800,"Aisha Khan,Northgate WP,Toronto,Wealth World ETF,BUY,05/10/2026,12000\n')
try:
    port.parse_csv(open(f"{BUILD}/datalake/samples/inbox/NORTHGATE/northgate_trades_2026-10-06.csv", encoding="utf-8").read(), ",")
    raise SystemExit("the damaged sample file parsed; it must fail")
except port.CsvError if hasattr(port, "CsvError") else Exception as e:
    print("damaged sample fails as intended:", e)

# ---------------------------------------------------------------- seed script (upsert by profile name)


def lit(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


blocks = []
for p in PROFILES:
    hdrs = ", ".join(lit(h) for h in p["headers"])
    cmap = ", ".join(f"{lit(k)} => {lit(v)}" for k, v in p["cmap"].items())
    aum = lit(p["aum"]) if p["aum"] else "null"
    blocks.append(f"""profiles.add(build(
    {lit(p['name'])}, {lit(p['code'])}, firmIds.get({lit(FIRM_NAMES[p['firm']])}), {lit(p['feed'])}, {aum},
    new List<String>{{ {hdrs} }},
    new Map<String, String>{{ {cmap} }},
    {lit(p['date'])}, {lit(p['sep'])}, {lit(p['conv'])}, {str(p['single']).lower()}
));""")
firm_list = ", ".join(lit(n) for n in dict.fromkeys(FIRM_NAMES[p["firm"]] for p in PROFILES))
seed_script = f"""// Creates or updates the Active mapping profiles for the sample feeds, matched by profile name.
// Phase 3: Barder's export gains a Record Type column (AUM rows), Northgate maps Branch, AUM indicators
// are set, and a Barder advisor code roster profile is added. KESTREL is left without a profile on purpose.
// Safe to re-run. Run: sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo

Mapping_Profile__c build(String name, String firmCode, Id firmId, String feedType, String aumIndicators, List<String> headers,
                         Map<String, String> columnMap, String dateFormat, String decimalSeparator, String convention, Boolean singleFirm) {{
    if (singleFirm && firmId == null) {{
        throw new System.IllegalArgumentException('Firm Account not found for ' + firmCode + '. Load the phase 1 seed data first.');
    }}
    return new Mapping_Profile__c(
        Name = name, Source_Firm__c = firmCode, Firm__c = firmId, Single_Firm_Feed__c = singleFirm, Feed_Type__c = feedType,
        AUM_Indicator_Values__c = aumIndicators, Header_Fingerprint__c = MappingService.fingerprint(headers),
        Column_Map__c = JSON.serializePretty(columnMap), Date_Format__c = dateFormat, Decimal_Separator__c = decimalSeparator,
        Direction_Convention__c = convention, Status__c = 'Active'
    );
}}

Map<String, Id> firmIds = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE ParentId = null AND Name IN :new List<String>{{ {firm_list} }}]) {{
    firmIds.put(a.Name, a.Id);
}}

List<Mapping_Profile__c> profiles = new List<Mapping_Profile__c>();
{chr(10).join(blocks)}

Map<String, Id> existing = new Map<String, Id>();
for (Mapping_Profile__c p : [SELECT Id, Name FROM Mapping_Profile__c WHERE Name IN :new List<String>{{ {', '.join(lit(p['name']) for p in PROFILES)} }}]) {{
    existing.put(p.Name, p.Id);
}}
Integer created = 0;
Integer updated = 0;
for (Mapping_Profile__c p : profiles) {{
    if (existing.containsKey(p.Name)) {{
        p.Id = existing.get(p.Name);
        updated++;
    }} else {{
        created++;
    }}
}}
upsert profiles;
System.debug(LoggingLevel.INFO, 'Mapping profiles created: ' + created + ', updated: ' + updated);
"""
os.makedirs(f"{BUILD}/scripts/apex", exist_ok=True)
with open(f"{BUILD}/scripts/apex/seed-mapping-profiles.apex", "w", encoding="utf-8", newline="\n") as fh:
    fh.write(seed_script)

# ---------------------------------------------------------------- DemoScenarioTest.cls
def a(v):
    return apex_str(v)


setup = []
setup.append("Map<String, Account> firms = new Map<String, Account>();")
for k, n in FIRM_NAMES.items():
    setup.append(f"firms.put({a(k)}, new Account(Name = {a(n)}));")
setup.append("insert firms.values();")
setup.append("Map<String, Account> accounts = new Map<String, Account>(firms);")
setup.append("Map<String, Account> branches = new Map<String, Account>();")
for k, p in ACCOUNT_PARENT.items():
    setup.append(f"branches.put({a(k)}, new Account(Name = {a(ACCOUNT_NAMES[k])}, ParentId = firms.get({a(p)}).Id));")
setup.append("insert branches.values();")
setup.append("accounts.putAll(branches);")
setup.append("Map<String, Contact> people = new Map<String, Contact>();")
for k, c in CONTACTS.items():
    setup.append(f"people.put({a(k)}, new Contact(FirstName = {a(c['first'])}, LastName = {a(c['last'])}, AccountId = accounts.get({a(c['account'])}).Id));")
setup.append("insert people.values();")
setup.append("Map<String, Product2> funds = new Map<String, Product2>();")
for k, n in FUND_NAMES.items():
    setup.append(f"funds.put({a(k)}, new Product2(Name = {a(n)}, IsActive = true));")
setup.append("insert funds.values();")
setup.append("Map<String, Rep_Code__c> codes = new Map<String, Rep_Code__c>();")
for rc in REP_CODES:
    setup.append(f"codes.put({a(rc['ref'])}, new Rep_Code__c(Name = {a(rc['name'])}, Firm__c = firms.get({a(rc['firm'])}).Id));")
setup.append("insert codes.values();")
setup.append("List<Rep_Code_Assignment__c> assignments = new List<Rep_Code_Assignment__c>();")
for x in ASSIGNMENTS:
    ds = lambda v: "null" if v is None else f"Date.newInstance({v.year}, {v.month}, {v.day})"
    setup.append(
        f"assignments.add(new Rep_Code_Assignment__c(Rep_Code__c = codes.get({a(x['code'])}).Id, Advisor__c = people.get({a(x['advisor'])}).Id, "
        f"Allocation_Percent__c = {x['pct']}, Effective_Start_Date__c = {ds(x['start'])}, Effective_End_Date__c = {ds(x['end'])}, "
        f"End_Date_Source__c = {a(x['src'])}, Last_Confirmed_Trade_Date__c = {ds(x['last'])}));")
setup.append("insert assignments;")
setup.append("List<SObject> aliases = new List<SObject>();")
for (key, f), (name, _) in zip(FIRM_ALIASES, seed["firm_alias_src"]):
    setup.append(f"aliases.add(new Firm_Alias__c(Name = {a(name)}, Normalized_Key__c = {a(key)}, Firm__c = firms.get({a(f)}).Id));")
for (key, f), (name, _) in zip(FUND_ALIASES, seed["fund_alias_src"]):
    setup.append(f"aliases.add(new Fund_Alias__c(Name = {a(name)}, Normalized_Key__c = {a(key)}, Fund__c = funds.get({a(f)}).Id));")
setup.append("insert aliases;")
setup.append("List<Mapping_Profile__c> profiles = new List<Mapping_Profile__c>();")
for p in PROFILES:
    hdrs = ", ".join(a(h) for h in p["headers"])
    cmap = ", ".join(f"{a(k)} => {a(v)}" for k, v in p["cmap"].items())
    setup.append(
        f"profiles.add(new Mapping_Profile__c(Name = {a(p['name'])}, Source_Firm__c = {a(p['code'])}, Firm__c = firms.get({a(p['firm'])}).Id, "
        f"Single_Firm_Feed__c = {str(p['single']).lower()}, Feed_Type__c = {a(p['feed'])}, AUM_Indicator_Values__c = {a(p['aum'])}, "
        f"Header_Fingerprint__c = MappingService.fingerprint(new List<String>{{ {hdrs} }}), "
        f"Column_Map__c = JSON.serialize(new Map<String, String>{{ {cmap} }}), Date_Format__c = {a(p['date'])}, "
        f"Decimal_Separator__c = {a(p['sep'])}, Direction_Convention__c = {a(p['conv'])}, Status__c = 'Active'));")
setup.append("insert profiles;")


def expect_rows(label, rows, contacts=CONTACTS, override=None):
    lines = []
    for r in rows:
        m, flags = r["match"], r["flags"]
        if override and r["row"] in override:
            m, flags = override[r["row"]]
        credited = contact_name(m["credited"], contacts) if m.get("credited") else None
        fund = FUND_NAMES[m["fund"]] if m.get("fund") else None
        lines.append("new List<String>{ " + ", ".join(a(v) for v in [
            str(r["row"]), m["status"], m.get("reason"), credited, fund, ";".join(flags) if flags else None]) + " }")
    return ",\n            ".join(lines)


def csv_lit(label):
    return a(sims[label][3])


fu_lines = ",\n            ".join(
    f"new List<String>{{ {a(k)}, '{v[0]}', '{v[1]}' }}" for k, v in sorted(FU.items()))
resolved_override = {row: (m, flags) for row, (m, flags) in resolved.items()}

test = f"""// Generated by tools/verify/gen_samples3.py from the same sample files shipped in datalake/samples.
// The expected outcomes come from the Python simulation, so this test proves the Apex and the simulation agree.
@IsTest
private class DemoScenarioTest {{
    @TestSetup
    static void buildWorld() {{
        // The phase 1 seed data and phase 3 mapping profiles, exactly as deployed.
        {(chr(10) + '        ').join(setup)}
    }}

    private static final String BARDER_CSV = {csv_lit('BARDER')};
    private static final String NORTHGATE_CSV = {csv_lit('NORTHGATE')};
    private static final String LUMIERE_CSV = {csv_lit('LUMIERE')};
    private static final String KESTREL_CSV = {csv_lit('KESTREL')};
    private static final String ROSTER_CSV = {csv_lit('ROSTER')};

    /** Ingests and matches files synchronously, exactly as the queued jobs would. */
    private static Map<String, Id> ingest(Map<String, String> csvByLabel, Map<String, String> firmByLabel) {{
        Map<String, Id> ids = new Map<String, Id>();
        for (String label : csvByLabel.keySet()) {{
            Import_Batch__c batch = TestDataFactory.receivedBatch(firmByLabel.get(label), csvByLabel.get(label));
            new ImportBatchProcessor(batch.Id).execute(null);
            ids.put(label, batch.Id);
        }}
        TradeMatcher.run(new Set<Id>(ids.values()));
        return ids;
    }}

    private static void assertRows(String label, Id batchId, List<List<String>> expected) {{
        List<Import_Staging_Row__c> rows = [
            SELECT Row_Number__c, Match_Status__c, Code_Follow_Up__r.Reason__c, Credited_Advisor__r.FirstName,
                Credited_Advisor__r.LastName, Matched_Fund__r.Name, Match_Flags__c
            FROM Import_Staging_Row__c
            WHERE Import_Batch__c = :batchId
            ORDER BY Row_Number__c
        ];
        Assert.areEqual(expected.size(), rows.size(), label + ': row count');
        for (Integer i = 0; i < rows.size(); i++) {{
            Import_Staging_Row__c r = rows[i];
            List<String> e = expected[i];
            String context = label + ' row ' + e[0] + ': ';
            Assert.areEqual(Integer.valueOf(e[0]), r.Row_Number__c.intValue(), context + 'row number');
            Assert.areEqual(e[1], r.Match_Status__c, context + 'status; flags ' + r.Match_Flags__c);
            Assert.areEqual(e[2], r.Code_Follow_Up__r?.Reason__c, context + 'follow-up reason');
            String credited = r.Credited_Advisor__c == null ? null : ((r.Credited_Advisor__r.FirstName == null ? '' : r.Credited_Advisor__r.FirstName + ' ') + r.Credited_Advisor__r.LastName);
            Assert.areEqual(e[3], credited, context + 'credited advisor');
            Assert.areEqual(e[4], r.Matched_Fund__r?.Name, context + 'matched fund');
            Assert.areEqual(e[5], r.Match_Flags__c, context + 'flags');
        }}
    }}

    @IsTest
    static void tradeFilesMatchSimulatedOutcomes() {{
        Map<String, Id> ids = ingest(
            new Map<String, String>{{ 'BARDER' => BARDER_CSV, 'NORTHGATE' => NORTHGATE_CSV, 'LUMIERE' => LUMIERE_CSV, 'KESTREL' => KESTREL_CSV }},
            new Map<String, String>{{ 'BARDER' => 'BARDER', 'NORTHGATE' => 'NORTHGATE', 'LUMIERE' => 'LUMIERE', 'KESTREL' => 'KESTREL' }}
        );
        Map<Id, Import_Batch__c> batches = new Map<Id, Import_Batch__c>([
            SELECT Id, Status__c, Matched_Row_Count__c, Review_Row_Count__c, Held_Row_Count__c, Error_Row_Count__c
            FROM Import_Batch__c
        ]);
        Assert.areEqual('Mapping Review', batches.get(ids.get('KESTREL')).Status__c, 'unknown layout');
        for (String label : new List<String>{{ 'BARDER', 'NORTHGATE', 'LUMIERE' }}) {{
            Assert.areEqual('Pending Review', batches.get(ids.get(label)).Status__c, label + ' status');
        }}
        assertRows('BARDER', ids.get('BARDER'), new List<List<String>>{{
            {expect_rows('BARDER', sims['BARDER'][2])}
        }});
        assertRows('NORTHGATE', ids.get('NORTHGATE'), new List<List<String>>{{
            {expect_rows('NORTHGATE', sims['NORTHGATE'][2])}
        }});
        assertRows('LUMIERE', ids.get('LUMIERE'), new List<List<String>>{{
            {expect_rows('LUMIERE', sims['LUMIERE'][2])}
        }});

        List<List<String>> followUps = new List<List<String>>{{
            {fu_lines}
        }};
        Map<String, Code_Follow_Up__c> byKey = new Map<String, Code_Follow_Up__c>();
        // Follow-ups are keyed by the matched firm; the expectations name the dealer that sent the file.
        Map<String, String> dealerOf = new Map<String, String>{{
            'Barder & Company' => 'BARDER',
            'Northgate Wealth Partners Inc.' => 'NORTHGATE',
            'Lumière Valeurs Mobilières Ltée' => 'LUMIERE'
        }};
        for (Code_Follow_Up__c f : [SELECT Firm__r.Name, Rep_Code_Value__c, Reason__c, Held_Row_Count__c, Held_Amount__c, Status__c FROM Code_Follow_Up__c]) {{
            byKey.put(dealerOf.get(f.Firm__r.Name) + '|' + f.Rep_Code_Value__c + '|' + f.Reason__c, f);
        }}
        Assert.areEqual(followUps.size(), byKey.size(), 'one follow-up per firm, code and reason: ' + byKey.keySet());
        for (List<String> e : followUps) {{
            Code_Follow_Up__c f = byKey.get(e[0]);
            Assert.isNotNull(f, 'follow-up exists: ' + e[0]);
            Assert.areEqual('Open', f.Status__c, e[0] + ' status');
            Assert.areEqual(Integer.valueOf(e[1]), f.Held_Row_Count__c.intValue(), e[0] + ' held rows');
            Assert.areEqual(Decimal.valueOf(e[2]), f.Held_Amount__c, e[0] + ' held amount');
        }}
    }}

    @IsTest
    static void resolvingFollowUpRematchesHeldRows() {{
        Map<String, Id> ids = ingest(new Map<String, String>{{ 'BARDER' => BARDER_CSV }}, new Map<String, String>{{ 'BARDER' => 'BARDER' }});
        // The firm confirms Priya Nair took over code 2210 on 15 September.
        Account hamilton = [SELECT Id FROM Account WHERE Name = 'Barder & Company - Hamilton'];
        Contact priya = new Contact(FirstName = 'Priya', LastName = 'Nair', AccountId = hamilton.Id);
        insert priya;
        Rep_Code_Assignment__c marcus = [SELECT Id FROM Rep_Code_Assignment__c WHERE Rep_Code__r.Name = '2210'];
        update new Rep_Code_Assignment__c(Id = marcus.Id, Effective_End_Date__c = Date.newInstance(2026, 9, 14), End_Date_Source__c = 'Confirmed by Firm');
        Rep_Code__c code2210 = [SELECT Id FROM Rep_Code__c WHERE Name = '2210'];
        insert new Rep_Code_Assignment__c(Rep_Code__c = code2210.Id, Advisor__c = priya.Id, Allocation_Percent__c = 100, Effective_Start_Date__c = Date.newInstance(2026, 9, 15));
        Code_Follow_Up__c f = [SELECT Id FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '2210' AND Reason__c = 'Reassignment Suspected'];

        Test.startTest();
        update new Code_Follow_Up__c(Id = f.Id, Status__c = 'Resolved');
        Test.stopTest();

        assertRows('BARDER resolved', ids.get('BARDER'), new List<List<String>>{{
            {expect_rows('BARDER', sims['BARDER'][2], contacts_after, resolved_override)}
        }});
        f = [SELECT Status__c, Held_Row_Count__c, Held_Amount__c FROM Code_Follow_Up__c WHERE Id = :f.Id];
        Assert.areEqual('Resolved', f.Status__c, 'stays resolved');
        Assert.areEqual(0, f.Held_Row_Count__c.intValue(), 'nothing held');
    }}

    @IsTest
    static void resolvingWithoutFixingTheCodeReopensTheFollowUp() {{
        ingest(new Map<String, String>{{ 'BARDER' => BARDER_CSV }}, new Map<String, String>{{ 'BARDER' => 'BARDER' }});
        Code_Follow_Up__c f = [SELECT Id FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '3390' AND Reason__c = 'Unknown Code'];
        Test.startTest();
        update new Code_Follow_Up__c(Id = f.Id, Status__c = 'Resolved');
        Test.stopTest();
        f = [SELECT Status__c, Held_Row_Count__c FROM Code_Follow_Up__c WHERE Id = :f.Id];
        Assert.areEqual('Open', f.Status__c, 'code 3390 is still unknown, so the follow-up reopens');
        Assert.areEqual(1, f.Held_Row_Count__c.intValue(), 'row held again');
    }}

    @IsTest
    static void closingFollowUpSendsRowsToReview() {{
        Map<String, Id> ids = ingest(new Map<String, String>{{ 'NORTHGATE' => NORTHGATE_CSV }}, new Map<String, String>{{ 'NORTHGATE' => 'NORTHGATE' }});
        Code_Follow_Up__c f = [SELECT Id FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '5521' AND Reason__c = 'Code Dormant'];
        Test.startTest();
        update new Code_Follow_Up__c(Id = f.Id, Status__c = 'Closed - No Action');
        Test.stopTest();
        Import_Staging_Row__c row = [SELECT Match_Status__c, Match_Flags__c, Code_Follow_Up__c FROM Import_Staging_Row__c WHERE Import_Batch__c = :ids.get('NORTHGATE') AND Row_Number__c = 9];
        Assert.areEqual('Needs Review', row.Match_Status__c, 'closed follow-up sends the row to review');
        Assert.isTrue(row.Match_Flags__c.endsWith('FOLLOW_UP_CLOSED'), 'flags: ' + row.Match_Flags__c);
        Assert.isNull(row.Code_Follow_Up__c, 'no longer linked');
        Assert.areEqual(0, [SELECT Held_Row_Count__c FROM Code_Follow_Up__c WHERE Id = :f.Id].Held_Row_Count__c.intValue(), 'count cleared');
    }}

    @IsTest
    static void rosterFileIsClassifiedForReview() {{
        Map<String, Id> ids = ingest(new Map<String, String>{{ 'ROSTER' => ROSTER_CSV }}, new Map<String, String>{{ 'ROSTER' => 'BARDER' }});
        assertRows('ROSTER', ids.get('ROSTER'), new List<List<String>>{{
            {expect_rows('ROSTER', sims['ROSTER'][2])}
        }});
        Assert.areEqual(0, [SELECT COUNT() FROM Code_Follow_Up__c], 'roster rows never create follow-ups');
    }}
}}
"""
with open(f"{APEX}/DemoScenarioTest.cls", "w", encoding="utf-8") as fh:
    fh.write(test)
print("samples, seed script and DemoScenarioTest written")
