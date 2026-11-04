"""Second-week sample files (dated 2026-10-12), one per dealer whose format already has a mapping profile.

The 2026-10-05 files are built to show traps, so most of what reaches Claude there is genuinely uncertain and comes
back Low. These files add rows that matching cannot settle on its own but whose evidence is clear, so Claude's
suggestions show a realistic mix: mostly High, some Medium, one Low. Every row is synthetic.

Each row lands where the comment says; the script checks that against the matching simulation (port.py) and stops if
any row lands elsewhere. Run: python3 tools/verify/gen_samples_mix.py
"""
import contextlib, io, os, runpy, sys

sys.path.insert(0, os.path.dirname(__file__))
with contextlib.redirect_stdout(io.StringIO()):
    g = runpy.run_path(os.path.join(os.path.dirname(__file__), "gen_samples3.py"))
NNBSP = g["NNBSP"]
BUILD = g["BUILD"]

# expected: (status, flag Claude is asked about or None), and the confidence Claude should reasonably give.
FILES = [
    dict(code="BARDER", folder="inbox", name="barder_trades_2026-10-12.csv", delim=",", eol="\r\n", bom=True, rows=[
        (["10/05/2026", "0457", "Julia Morales", "Barder and Co", "Wealth World ETF", "TRADE", "$30,000.00"], "Matched", None),
        (["10/06/2026", "0457", "Julia Morales", "Barder and Co", "Global Bond Fd Ser F", "TRADE", "$62,000.00"], "Needs Review", "FUND_UNRESOLVED"),  # High: one Global Bond fund
        (["10/07/2026", "0457", "Julia Morales", "Barder Wealth Management", "Wealth World Fund A", "TRADE", "$18,000.00"], "Needs Review", "FIRM_UNRESOLVED"),  # High: 457 is Barder's, Julia holds it
        (["10/08/2026", "0457", "J. Morales", "Barder and Co", "Cdn Div Fund Ser A", "TRADE", "-$24,500.00"], "Needs Review", "FUND_UNRESOLVED"),  # High: one dividend fund
        (["10/09/2026", "0457", "Julia Morales", "Barder and Co", "Canadian Dividend Fund, Series A", "TRADE", "$11,250.00"], "Matched", None),
        (["10/09/2026", "0457", "Julia Morales", "Barder and Co", "WW Fund Ser F", "TRADE", "$15,000.00"], "Needs Review", "FUND_UNRESOLVED"),  # Medium: WW abbreviation
    ]),
    dict(code="NORTHGATE", folder="inbox", name="northgate_trades_2026-10-12.csv", delim=",", eol="\n", bom=False, rows=[
        (["8800", "Aisha Khan", "Northgate Wealth Ptnrs", "Toronto", "Wealth World Fund - Series F", "BUY", "06/10/2026", "85000"], "Needs Review", "FIRM_UNRESOLVED"),  # High
        (["8800", "Daniel Okafor", "Northgate WP", "Toronto", "Global Bond Fund Ser. F", "SELL", "07/10/2026", "26000"], "Needs Review", "FUND_UNRESOLVED"),  # High
        (["8800", "Aisha Khan", "Northgate WP", "Toronto", "Wealth World Fund - Series A", "BUY", "08/10/2026", "140000"], "Matched", None),
        (["8800", "D. Okafor", "Northgate WP", "Toronto", "Cdn Dividend Fd - Ser A", "BUY", "09/10/2026", "32500"], "Needs Review", "FUND_UNRESOLVED"),  # High
        (["8800", "Aisha Khan", "Northgate WP", "Toronto", "World Wealth Balanced Fund", "BUY", "09/10/2026", "20000"], "Needs Review", "FUND_UNRESOLVED"),  # Low: no balanced fund exists
    ]),
    dict(code="LUMIERE", folder="inbox", name="lumiere_transactions_2026-10-12.csv", delim=";", eol="\r\n", bom=True, rows=[
        (["2026-10-06", "7700", "Élise Gagnon", "Lumiere VM", "Wealth World Fund - Series A", "ACHAT", f"95{NNBSP}000,00"], "Needs Review", "FIRM_UNRESOLVED"),  # High/Medium: VM = Valeurs Mobilières
        (["2026-10-07", "7700", "Marc-André Roy", "Lumiere Valeurs Mobilieres", "Fonds d'obligations mondiales - Série F", "RACHAT", f"31{NNBSP}200,00"], "Needs Review", "FUND_UNRESOLVED"),  # Medium: French name for Global Bond F
        (["2026-10-08", "7700", "Élise Gagnon", "Lumiere Valeurs Mobilieres", "Fonds de dividendes canadiens - Série A", "ACHAT", f"14{NNBSP}750,00"], "Needs Review", "FUND_UNRESOLVED"),  # High/Medium: French name for Canadian Dividend A
        (["2026-10-09", "7700", "Marc-André Roy", "Lumiere Valeurs Mobilieres", "Wealth World ETF", "ACHAT", f"8{NNBSP}500,00"], "Matched", None),
    ]),
]

w = g["world"]()
problems = []
for f in FILES:
    rows = [r for r, _, _ in f["rows"]]
    sim = dict(f, rows=rows)
    status, out, text = g["simulate"](sim, w)
    assert status == "Pending Review", (f["name"], status)
    for (r, want, flag), n in zip(f["rows"], out):
        got = n["match"]["status"]
        ok = got == want and (flag is None or flag in n["flags"])
        print(f"{f['code']:<10} row {n['row']:>2}  {got:<13} {','.join(n['flags']) or '-':<40} {'ok' if ok else 'MISMATCH'}")
        if not ok:
            problems.append((f["name"], n["row"], got, n["flags"]))
    path = f"{BUILD}/datalake/samples/{f['folder']}/{f['code']}/{f['name']}"
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
if problems:
    raise SystemExit(f"rows not where intended: {problems}")
print("all rows land as intended")
