"""Builds synthetic seed data (sObject tree format) with planted matching traps."""
import json, os

OUT = "build/data"
os.makedirs(OUT, exist_ok=True)

# Python replica of NameNormalizer.firmKey() so seeded keys match what Apex will compute
SUFFIXES = ['and company', 'and co', 'and c', 'et compagnie', 'et cie',
            'incorporated', 'corporation', 'limited', 'company', 'compagnie',
            'corp', 'inc', 'ltd', 'ltée', 'ltee', 'llp', 'lp', 'cie', 'co', 'and', 'et']


def key(raw):
    s = raw.lower().replace('&', ' and ')
    s = ''.join(c if (c.isalnum() or c == ' ') else ' ' for c in s)
    s = ' '.join(s.split())
    stripped = True
    while stripped:
        stripped = False
        for suf in SUFFIXES:
            if s.endswith(' ' + suf):
                s = ' '.join(s[:-len(' ' + suf)].split())
                stripped = True
                break
    return s


def rec(type_, ref, **fields):
    return {"attributes": {"type": type_, "referenceId": ref}, **fields}


def dump(name, records):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        json.dump({"records": records}, f, indent=2, ensure_ascii=False)


firms = [
    rec("Account", "FirmBarder", Name="Barder & Company", Description="Synthetic firm. Trap: name arrives as Barder and Co / Barder and C."),
    rec("Account", "FirmNorthgate", Name="Northgate Wealth Partners Inc.", Description="Synthetic firm. Trap: shared team code 8800 with a departed member; dormant code 5521."),
    rec("Account", "FirmLumiere", Name="Lumière Valeurs Mobilières Ltée", Description="Synthetic firm. Trap: French name and accents dropped in files; shared code 7700 split 60/40."),
    rec("Account", "FirmKestrelInc", Name="Kestrel Capital Inc.", Description="Synthetic firm. Trap: normalizes to the same key as Kestrel Capital Ltd. and both use rep code 1001."),
    rec("Account", "FirmKestrelLtd", Name="Kestrel Capital Ltd.", Description="Synthetic firm. Trap: normalizes to the same key as Kestrel Capital Inc. and both use rep code 1001."),
]
branches = [
    rec("Account", "BrBarderOak", Name="Barder & Company - Oakville", ParentId="@FirmBarder"),
    rec("Account", "BrBarderHam", Name="Barder & Company - Hamilton", ParentId="@FirmBarder"),
    rec("Account", "BrNorthTor", Name="Northgate Wealth Partners - Toronto", ParentId="@FirmNorthgate"),
    rec("Account", "BrLumMtl", Name="Lumière Valeurs Mobilières - Montréal", ParentId="@FirmLumiere"),
    rec("Account", "BrKesInc", Name="Kestrel Capital Inc. - Calgary", ParentId="@FirmKestrelInc"),
    rec("Account", "BrKesLtd", Name="Kestrel Capital Ltd. - Vancouver", ParentId="@FirmKestrelLtd"),
]
advisors = [
    ("AdvJulia", "Julia", "Morales", "BrBarderOak"),
    ("AdvMarcus", "Marcus", "Bell", "BrBarderHam"),
    ("AdvTom", "Tom", "Reilly", "BrNorthTor"),
    ("AdvAisha", "Aisha", "Khan", "BrNorthTor"),
    ("AdvDaniel", "Daniel", "Okafor", "BrNorthTor"),
    ("AdvSam", "Sam", "Whitford", "BrNorthTor"),
    ("AdvElise", "Élise", "Gagnon", "BrLumMtl"),
    ("AdvMarc", "Marc-André", "Roy", "BrLumMtl"),
    ("AdvRyan", "Ryan", "Chen", "BrKesInc"),
    ("AdvMegan", "Megan", "Chen", "BrKesLtd"),
]
contacts = [rec("Contact", r, FirstName=fn, LastName=ln, AccountId="@" + acct, Title="Investment Advisor")
            for r, fn, ln, acct in advisors]

funds = [
    ("FundWWFA", "Wealth World Fund - Series A", "WWF-A", "Mutual fund, Series A"),
    ("FundWWFF", "Wealth World Fund - Series F", "WWF-F", "Mutual fund, Series F"),
    ("FundWWE", "Wealth World ETF", "WWE", "Exchange-traded fund"),
    ("FundCDFA", "Canadian Dividend Fund - Series A", "CDF-A", "Mutual fund, Series A"),
    ("FundGBFF", "Global Bond Fund - Series F", "GBF-F", "Mutual fund, Series F"),
]
products = [rec("Product2", r, Name=n, ProductCode=c, Description=d, IsActive=True) for r, n, c, d in funds]

rep_codes = [
    rec("Rep_Code__c", "RcNorth3102", Name="3102", Firm__c="@FirmNorthgate"),
    rec("Rep_Code__c", "RcBarder457", Name="457", Firm__c="@FirmBarder"),
    rec("Rep_Code__c", "RcBarder2210", Name="2210", Firm__c="@FirmBarder"),
    rec("Rep_Code__c", "RcNorth5521", Name="5521", Firm__c="@FirmNorthgate"),
    rec("Rep_Code__c", "RcLum7700", Name="7700", Firm__c="@FirmLumiere"),
    rec("Rep_Code__c", "RcNorth8800", Name="8800", Firm__c="@FirmNorthgate"),
    rec("Rep_Code__c", "RcKesInc1001", Name="1001", Firm__c="@FirmKestrelInc"),
    rec("Rep_Code__c", "RcKesLtd1001", Name="1001", Firm__c="@FirmKestrelLtd"),
]


def asg(ref, code, adv, pct, start, last, end=None, src=None):
    r = rec("Rep_Code_Assignment__c", ref, Rep_Code__c="@" + code, Advisor__c="@" + adv,
            Allocation_Percent__c=pct, Effective_Start_Date__c=start, Last_Confirmed_Trade_Date__c=last)
    if end:
        r["Effective_End_Date__c"] = end
        r["End_Date_Source__c"] = src
    return r


assignments = [
    # Trap: Julia moved from Northgate (3102) to Barder (457)
    asg("AsJulia3102", "RcNorth3102", "AdvJulia", 100, "2019-03-01", "2024-05-28", "2024-05-28", "Inferred from Review"),
    asg("AsJulia457", "RcBarder457", "AdvJulia", 100, "2024-06-15", "2026-09-28"),
    # Trap: 2210 will be silently reassigned (new advisor appears in phase 2 files)
    asg("AsMarcus2210", "RcBarder2210", "AdvMarcus", 100, "2018-01-08", "2025-11-14"),
    # Trap: dormant code reactivates
    asg("AsTom5521", "RcNorth5521", "AdvTom", 100, "2020-09-01", "2025-02-03"),
    # Trap: shared code 60/40
    asg("AsElise7700", "RcLum7700", "AdvElise", 60, "2021-01-04", "2026-09-30"),
    asg("AsMarc7700", "RcLum7700", "AdvMarc", 40, "2021-01-04", "2026-09-30"),
    # Trap: team code with a departed member -> active total 80%
    asg("AsAisha8800", "RcNorth8800", "AdvAisha", 50, "2022-04-01", "2026-09-25"),
    asg("AsDaniel8800", "RcNorth8800", "AdvDaniel", 30, "2022-04-01", "2026-09-25"),
    asg("AsSam8800", "RcNorth8800", "AdvSam", 20, "2022-04-01", "2026-03-27", "2026-03-31", "Confirmed by Firm"),
    # Trap: same code at two near-identical firms
    asg("AsRyan1001", "RcKesInc1001", "AdvRyan", 100, "2023-02-01", "2026-09-15"),
    asg("AsMegan1001", "RcKesLtd1001", "AdvMegan", 100, "2021-06-01", "2026-08-30"),
]

firm_alias_src = [
    ("Barder & Company", "FirmBarder"),
    ("Northgate Wealth Partners Inc.", "FirmNorthgate"),
    ("Northgate WP", "FirmNorthgate"),
    ("Lumière Valeurs Mobilières Ltée", "FirmLumiere"),
    ("Lumiere Valeurs Mobilieres", "FirmLumiere"),
    ("Kestrel Capital Inc.", "FirmKestrelInc"),
    ("Kestrel Capital Ltd.", "FirmKestrelLtd"),
]
firm_aliases = [rec("Firm_Alias__c", f"FA{i}", Name=n, Normalized_Key__c=key(n), Firm__c="@" + f)
                for i, (n, f) in enumerate(firm_alias_src, 1)]

# "ETF Wealth World Fund A" is deliberately NOT aliased: ambiguous between the ETF and Series A
fund_alias_src = [
    ("Wealth World Fund - Series A", "FundWWFA"),
    ("Wealth World Fund A", "FundWWFA"),
    ("WEALTH WORLD FD SER A", "FundWWFA"),
    ("Wealth World Fund - Series F", "FundWWFF"),
    ("Wealth World ETF", "FundWWE"),
    ("Canadian Dividend Fund - Series A", "FundCDFA"),
    ("Cdn Dividend Fund A", "FundCDFA"),
    ("Global Bond Fund - Series F", "FundGBFF"),
    # Trap (phase 4b): dealers write "Wealth World Fund" for both series, so this spelling must always go to review.
    ("Wealth World Fund", "FundWWFA"),
    ("Wealth World Fund", "FundWWFF"),
]
fund_aliases = [rec("Fund_Alias__c", f"FU{i}", Name=n, Normalized_Key__c=key(n), Fund__c="@" + f)
                for i, (n, f) in enumerate(fund_alias_src, 1)]

files = [
    ("Account", "Account-firms.json", firms, True, False),
    ("Account", "Account-branches.json", branches, True, True),
    ("Contact", "Contact.json", contacts, True, True),
    ("Product2", "Product2.json", products, True, False),
    ("Rep_Code__c", "Rep_Code__c.json", rep_codes, True, True),
    ("Rep_Code_Assignment__c", "Rep_Code_Assignment__c.json", assignments, False, True),
    ("Firm_Alias__c", "Firm_Alias__c.json", firm_aliases, False, True),
    ("Fund_Alias__c", "Fund_Alias__c.json", fund_aliases, False, True),
]
plan = []
for sobj, fname, recs, save, resolve in files:
    dump(fname, recs)
    plan.append({"sobject": sobj, "saveRefs": save, "resolveRefs": resolve, "files": [fname]})
with open(os.path.join(OUT, "seed-plan.json"), "w", encoding="utf-8") as f:
    json.dump(plan, f, indent=2)

for n, _ in firm_alias_src:
    print(f"{n!r:40} -> {key(n)!r}")
for n, _ in fund_alias_src:
    print(f"{n!r:40} -> {key(n)!r}")
print("Barder and Co ->", key("Barder and Co"), "| Barder and C. ->", key("Barder and C."),
      "| Barder & Co., Inc. ->", key("Barder & Co., Inc."))
