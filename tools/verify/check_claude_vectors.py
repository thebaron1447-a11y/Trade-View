"""Checks the Claude response vectors (suggestions, parsing, mapping proposals, reviewer-facing text) against the
Python port. The same vectors are compiled into ClaudeValidationVectorTest. Run: python check_claude_vectors.py"""
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
import port


# The items a suggestion request sent: what each may answer and from which keys.
ITEMS = {
    "R1": dict(asks={"firm"}, allowed={"firm": {"F1", "F2"}}),
    "R2": dict(asks={"fund"}, allowed={"fund": {"P1", "P2", "P3"}}),
    "R3": dict(asks={"advisor", "recommendation"}, allowed={"advisor": {"A1", "A2"}}),
    "U1": dict(asks={"advisor"}, allowed={"advisor": {"A3"}}),
}

def e(item, conf="High", expl="Evidence.", **kw):
    d = {"item": item}
    d.update(kw)
    if conf is not ...:
        d["confidence"] = conf
    if expl is not ...:
        d["explanation"] = expl
    return d

def resp(entries, fence=False):
    text = json.dumps({"suggestions": entries}, ensure_ascii=False)
    return "```json\n" + text + "\n```" if fence else text

LONG = "x" * 2500
SUGGESTION_VECTORS = [
    ("all valid in a code fence", resp([e("R1", firm="F2"), e("R2", fund="P1", conf="Medium"),
                                         e("R3", advisor="A1", recommendation="Approve"), e("U1", advisor=None, conf="low", expl="Not in Salesforce yet.")], fence=True)),
    ("invented firm key", resp([e("R1", firm="F9"), e("R2", fund="P3")])),
    ("unknown and duplicate items", resp([e("R9", firm="F1"), e("R1", firm="F1"), e("R1", firm="F2")])),
    ("bad confidence and lower case", resp([e("R1", firm="F1", conf="Sure"), e("R2", fund="P2", conf=" medium ")])),
    ("missing or blank explanation", resp([e("R1", firm="F1", expl=...), e("R2", fund="P2", expl="   ")])),
    ("unasked fields ignored", resp([e("R2", fund="P2", firm="F1", advisor="A9")])),
    ("bad recommendation", resp([e("R3", recommendation="maybe")])),
    ("recommendation not asked is ignored", resp([e("R1", firm="F1", recommendation="whatever")])),
    ("no suggestions key", '{"answer": []}'),
    ("suggestions is not a list", '{"suggestions": {"item": "R1"}}'),
    ("entry is not an object", resp(["R1", e("R2", fund="P1")])),
    ("numeric and null item", resp([{"item": 5, "confidence": "High", "explanation": "x"}, {"item": None}])),
    ("firm given as a number", resp([e("R1", firm=3)])),
    ("long explanation is shortened", resp([e("U1", advisor="A3", expl=LONG)])),
    ("confidence not text", resp([e("R1", firm="F1", conf=True)])),
    ("prose around the JSON", "Here is my answer:\n" + resp([e("R1", firm="F1")]) + "\nLet me know if you need more."),
]
PARSE_VECTORS = [
    ("no JSON", "I cannot help with that.", "The response contains no JSON object."),
    ("braces reversed", "} {", "The response contains no JSON object."),
    ("truncated JSON", '{"suggestions": [{"item": "R1"', "The response contains no JSON object."),
    ("invalid JSON", '{"suggestions": [oops]}', "The response is not valid JSON"),
    ("null", None, "The response contains no JSON object."),
]

KESTREL = ["Representative", "Rep No.", "Organisation", "Security Name", "Settle Date", "Side", "Value"]
GOOD_MAP = {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName",
            "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}
def proposal(**over):
    p = dict(feedType="Trade Activity", columnMap=dict(GOOD_MAP), dateFormat="YYYY-MM-DD", decimalSeparator="Period",
             directionConvention="Type Column", aumIndicatorValues=None, confidence="High", explanation="Side holds B or S.")
    p.update(over)
    return json.dumps(p)
PROPOSAL_VECTORS = [
    ("valid Kestrel proposal", proposal()),
    ("headers matched loosely", proposal(columnMap={"  rep no. ": "repCode", "REPRESENTATIVE": "advisorName", "Organisation": "firmName",
                                                    "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"})),
    ("extra and missing columns", proposal(columnMap={k: v for k, v in list(GOOD_MAP.items())[:-1]} | {"Units": "IGNORE"})),
    ("unknown field", proposal(columnMap=GOOD_MAP | {"Value": "units"})),
    ("same column twice", proposal(columnMap=GOOD_MAP | {"rep no.": "IGNORE"})),
    ("bad settings", proposal(dateFormat="DD-MM-YYYY", decimalSeparator="Dot", directionConvention=None, feedType="Trades")),
    ("AUM indicator as number", proposal(aumIndicatorValues=5)),
    ("blank AUM indicator becomes null", proposal(aumIndicatorValues="  ", confidence="medium")),
    ("column map not an object", proposal(columnMap=["Rep No."])),
    ("missing confidence and explanation", proposal(confidence=None, explanation="")),
]

# ---------------------------------------------------------------- check the port against hand-verified facts
fails = []
def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r}, want {want!r}")

results = []
for name, text in SUGGESTION_VECTORS:
    usable, by_item, invalid, problems = port.validate_suggestions(port.parse_object(text), ITEMS)
    results.append((name, text, usable, by_item, invalid, sorted(problems)))
r = {n: (u, b, i, p) for n, _, u, b, i, p in results}
# Hand-verified expectations (independent of the port's logic) for the cases that matter most.
check("valid usable", r["all valid in a code fence"][0], True)
check("valid items", sorted(r["all valid in a code fence"][1]), ["R1", "R2", "R3", "U1"])
check("valid recommendation", r["all valid in a code fence"][1]["R3"]["recommendation"], "approve")
check("valid low", r["all valid in a code fence"][1]["U1"]["confidence"], "Low")
check("invented key invalid", r["invented firm key"][2], {"R1"})
check("invented key other kept", list(r["invented firm key"][1]), ["R2"])
check("duplicate keeps first", r["unknown and duplicate items"][1]["R1"]["firm"], "F1")
check("unasked ignored", (r["unasked fields ignored"][1]["R2"]["firm"], r["unasked fields ignored"][1]["R2"]["advisor"]), (None, None))
check("no list unusable", r["no suggestions key"][0], False)
check("numeric item text", r["numeric and null item"][3], ["Entry 1 refers to an unknown item: 5.", "Entry 2 refers to an unknown item: null."])
check("long explanation", len(r["long explanation is shortened"][1]["U1"]["explanation"]), 2000)
check("prose ok", sorted(r["prose around the JSON"][1]), ["R1"])

parse_results = []
for name, text, want in PARSE_VECTORS:
    try:
        port.parse_object(text)
        got = "ok"
    except port.ClaudeError as ex:
        got = str(ex)
    check(f"parse {name}", got.startswith(want), True)
    parse_results.append((name, text, want))

proposal_results = []
for name, text in PROPOSAL_VECTORS:
    p, problems = port.validate_proposal(json.loads(text), KESTREL)
    proposal_results.append((name, text, p, sorted(problems)))
pr = {n: (p, probs) for n, _, p, probs in proposal_results}
check("valid proposal", pr["valid Kestrel proposal"][1], [])
check("valid proposal map", pr["valid Kestrel proposal"][0]["columnMap"], GOOD_MAP)
check("loose headers map to file headers", sorted(pr["headers matched loosely"][0]["columnMap"]), sorted(KESTREL))
check("extra/missing", pr["extra and missing columns"][1], ['Column "Value" has no mapping.', 'columnMap names a column that is not in the file: "Units".'])
check("blank aum", pr["blank AUM indicator becomes null"][0]["aumIndicatorValues"], None)
check("map not object", pr["column map not an object"][0], None)

# ---------------------------------------------------------------- 3B.2: keys never reach the reviewer
NAMES = {"F1": "Kestrel Capital Inc.", "P3": "Wealth World ETF", "P5": "Wealth World Fund - Series F",
         "A1": "Julia Morales", "A2": "", "R1": "row ISR-0000012", "U1": "the 3390 follow-up"}
LONG_KEYS = "x" * 1995 + " P3"
# (name, text, expected) - every expectation written by hand from the rule, not from the port.
READABLE_VECTORS = [
    ("live run 2026-10-19", "the 'Fund A' portion aligns with Series A rather than the Wealth World ETF (P3) or Series F (P5), so a reviewer should confirm.",
     "the 'Fund A' portion aligns with Series A rather than the Wealth World ETF or Series F, so a reviewer should confirm."),
    ("bracketed list", "It is not one of the ETFs (P3 or P5).", "It is not one of the ETFs."),
    ("bracketed comma list", "Two candidates (P3, P5) fit.", "Two candidates fit."),
    ("bare keys", "Suggest F1 for R1.", "Suggest Kestrel Capital Inc. for row ISR-0000012."),
    ("item key", "U1 can be closed once A1 confirms.", "the 3390 follow-up can be closed once Julia Morales confirms."),
    ("unknown keys untouched", "Code P9 and (P9) are not ours.", "Code P9 and (P9) are not ours."),
    ("bracket with an unknown key keeps brackets", "Fund (P3, P9).", "Fund (Wealth World ETF, P9)."),
    ("word edges", "Codes A12X, XA1 and A1.", "Codes A12X, XA1 and Julia Morales."),
    ("blank name untouched", "A2 is unnamed (A2).", "A2 is unnamed (A2)."),
    ("lower case untouched", "p3 is not a key.", "p3 is not a key."),
    ("no keys", "Plain text with no keys.", "Plain text with no keys."),
    ("bracket at start", "(F1) holds the code.", "holds the code."),
    ("adjacent brackets", "Kestrel Capital Inc. (F1)(P3) fits.", "Kestrel Capital Inc. fits."),
    ("bracketed and-list", "Neither fund (F1 and P3) fits.", "Neither fund fits."),
    ("long text is capped", LONG_KEYS, ("x" * 1995 + " Wealth World ETF")[:1997] + "..."),
]
readable_results = []
for name, text, want in READABLE_VECTORS:
    got = port.readable(text, NAMES)
    check(f"readable {name}", got, want)
    readable_results.append((name, text, got))
check("readable empty map", port.readable("F1", {}), "F1")
check("readable none", port.readable(None, NAMES), None)
check("readable long length", len(port.readable(LONG_KEYS, NAMES)), 2000)

if fails:
    print("3B VECTOR FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print(f"3B vectors pass ({len(SUGGESTION_VECTORS)} suggestion responses, {len(PARSE_VECTORS)} parse cases, {len(PROPOSAL_VECTORS)} mapping proposals, {len(READABLE_VECTORS)} readable-text cases)")
