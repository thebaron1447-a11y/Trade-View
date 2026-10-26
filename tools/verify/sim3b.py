"""Phase 3B end-to-end simulation of the Kestrel story, using the same world as the phase 1 seed:
Claude proposes a mapping -> the file is read -> 'Kestrel Capital' is ambiguous -> Claude suggests the firm from
the advisor -> reviewer accepts -> row re-matched and credited. Also the Barder fund row and the 3390 roster approval."""
import sys, os, io, contextlib, runpy
from datetime import date
from decimal import Decimal
sys.path.insert(0, os.path.dirname(__file__))
with contextlib.redirect_stdout(io.StringIO()):
    g = runpy.run_path(os.path.join(os.path.dirname(__file__), "gen_samples3.py"))
import port
from gen_tests3b import GOOD_MAP, KESTREL

W = g["W"]
problems = []

# 1. The proposal Claude is expected to make is valid and reads the Kestrel sample file.
kestrel = next(f for f in g["FILES"] if f["code"] == "KESTREL")
text = g["to_csv"](kestrel["headers"], kestrel["rows"], kestrel["delim"], kestrel["eol"], kestrel["bom"])
rows = port.parse_csv(text, port.detect_delimiter(text))
headers, data = rows[0], rows[1:]
assert headers == KESTREL, headers
prof = dict(code="KESTREL", name="KESTREL - proposed by Claude", firm=None, single=False, feed="Trade Activity", aum=None,
            headers=headers, cmap=GOOD_MAP, date="YYYY-MM-DD", sep="Period", conv="Type Column")
cols, col_problems = port.resolve_columns3(headers, GOOD_MAP, prof)
if col_problems:
    problems.append(f"proposed mapping fails file checks: {col_problems}")
staged = [port.normalize_row3(headers, r, cols, g["cfg_for"](prof), i + 1) for i, r in enumerate(data)]
for n in staged:
    if n["status"] == "Invalid":
        problems.append(f"Kestrel row {n['row']} invalid: {n.get('errors')}")

# 2. Matching before review: both rows ambiguous between the two Kestrel firms.
first = [port.match_row(n, W) for n in staged]
for (m, flags), n in zip(first, staged):
    if m["status"] != "Needs Review" or flags != ["FIRM_AMBIGUOUS"]:
        problems.append(f"Kestrel row {n['row']} before review: {m} {flags}")

# 3. Claude suggests Inc. for Ryan Chen (Calgary branch holds his code) and Ltd. for Megan Chen; reviewer accepts.
expected_firm = {"Ryan Chen": "FirmKestrelInc", "Megan Chen": "FirmKestrelLtd"}
after = []
for n in staged:
    firm = expected_firm[n["advisor"]]
    m, flags = port.match_row(dict(n, firmOverride=firm, aiFirm=firm), W)
    after.append((n, m, flags))
    # Each advisor holds code 1001 at their own firm, so with the firm settled the row matches fully.
    want_advisor = {"Ryan Chen": "AdvRyan", "Megan Chen": "AdvMegan"}[n["advisor"]]
    if m["status"] != "Matched" or flags != ["FIRM_FROM_CLAUDE"] or m["firm"] != firm or m["credited"] != want_advisor:
        problems.append(f"Kestrel row {n['row']} after accept: {m} {flags}")
    if m["fund"] is None:
        problems.append(f"Kestrel row {n['row']} fund not resolved")

# 4. A reviewer choosing a different firm than Claude is recorded as the reviewer's choice.
m, flags = port.match_row(dict(staged[0], firmOverride="FirmKestrelLtd", aiFirm="FirmKestrelInc"), W)
if flags[0] != "FIRM_FROM_REVIEWER":
    problems.append(f"reviewer override flag: {flags}")

# 5. Barder row 6: fund "ETF Wealth World Fund A" unresolved; reviewer picks Wealth World Fund - Series A.
barder = g["sims"]["BARDER"][2]
r6 = next(r for r in barder if r["row"] == 6)
m, flags = port.match_row(dict(r6, fundOverride="FundWWFA", aiFund=None), W)
if m["status"] != "Matched" or "FUND_FROM_REVIEWER" not in flags:
    problems.append(f"Barder row 6 after fund override: {m} {flags}")

if problems:
    print("3B SIMULATION PROBLEMS:\n" + "\n".join(problems))
    sys.exit(1)
for n, m, flags in after:
    print(f"KESTREL row {n['row']} {n['advisor']:<10} {n['date']} {n['type']:<10} {n['amount']:>9} -> {m['status']} [{m['reason']}] {flags}")
print("3B simulation matches design intent (Kestrel proposal, firm suggestion, override, fund override)")
