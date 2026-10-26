"""1) Checks every shared vector against the Python port. 2) Emits vector-driven Apex test classes."""
import sys, os
from decimal import Decimal
sys.path.insert(0, os.path.dirname(__file__))
import port, vectors as V

OUT = "/home/claude/apex"
fails = []


def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r}, want {want!r}")


for raw, want in V.FIRM_KEYS:
    check(f"firmKey {raw!r}", port.firm_key(raw), want)
for v, fmt, want in V.DATES:
    d = port.parse_date(v, fmt, [])
    check(f"date {v} {fmt}", d.isoformat() if d else None, want)
for v, sep, want in V.AMOUNTS:
    a = port.parse_amount(v, sep, [])
    check(f"amount {v!r} {sep}", None if a is None else str(a), want)
for v, want in V.REP_CODES:
    check(f"rep {v!r}", port.normalize_rep_code(v), want)
import re
for v, want in V.TYPES:
    check(f"type {v}", port.TYPE_SYNONYMS.get(re.sub(r"[^A-Z]", "", v.upper())), want)
for name, text, d, want in V.CSV:
    check(f"csv {name}", port.parse_csv(text, d), want)
for name, text, d in V.CSV_ERRORS:
    try:
        port.parse_csv(text, d)
        fails.append(f"csv error {name}: no exception")
    except port.CsvError:
        pass
for text, want in V.DELIMITERS:
    check(f"delim {text!r}", port.detect_delimiter(text), want)

if fails:
    print("VECTOR FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print(f"all vectors pass in the Python port "
      f"({len(V.FIRM_KEYS)} keys, {len(V.DATES)} dates, {len(V.AMOUNTS)} amounts, {len(V.REP_CODES)} codes, "
      f"{len(V.TYPES)} types, {len(V.CSV) + len(V.CSV_ERRORS)} csv, {len(V.DELIMITERS)} delimiters)")


# ---------------------------------------------------------------- Apex emission
SPECIAL = {"\u00a0": 160, "\u202f": 8239, "\ufeff": 65279}


def apex_str(s):
    if s is None:
        return "null"
    parts, buf = [], ""
    for ch in s:
        if ch in SPECIAL:
            if buf:
                parts.append(_lit(buf))
                buf = ""
            parts.append(f"String.fromCharArray(new List<Integer>{{ {SPECIAL[ch]} }})")
        else:
            buf += ch
    if buf or not parts:
        parts.append(_lit(buf))
    return " + ".join(parts)


def _lit(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "'"


def write(name, body):
    with open(f"{OUT}/{name}.cls", "w", encoding="utf-8") as f:
        f.write(body)


def pairs(lst):
    return ",\n            ".join(f"new List<String>{{ {apex_str(a)}, {apex_str(b)} }}" for a, b in lst)


def triples(lst):
    return ",\n            ".join(f"new List<String>{{ {apex_str(a)}, {apex_str(b)}, {apex_str(c)} }}" for a, b, c in lst)


HEADER = "// Generated from tools/verify/vectors.py; the same vectors are checked against a Python port before delivery.\n"

write("NameNormalizerTest", HEADER + f"""@IsTest
private class NameNormalizerTest {{
    @IsTest
    static void keysMatchVectors() {{
        List<List<String>> cases = new List<List<String>>{{
            {pairs(V.FIRM_KEYS)}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(c[1], NameNormalizer.firmKey(c[0]), 'firmKey for ' + c[0]);
        }}
    }}

    @IsTest
    static void nullInputReturnsNull() {{
        Assert.isNull(NameNormalizer.firmKey(null), 'null input');
    }}
}}
""")

csv_cases = []
for name, text, d, rows in V.CSV:
    rows_ex = "new List<List<String>>{ " + ", ".join(
        "new List<String>{ " + ", ".join(apex_str(v) for v in r) + " }" for r in rows) + " }"
    csv_cases.append(f"        assertRows({apex_str(name)}, CsvParser.parse({apex_str(text)}, {apex_str(d)}), {rows_ex});")
csv_err = "\n".join(
    f"        assertThrows({apex_str(t)}, {apex_str(d)}, {apex_str(n)});" for n, t, d in V.CSV_ERRORS)
delim = "\n".join(
    f"        Assert.areEqual({apex_str(w)}, CsvParser.detectDelimiter({apex_str(t)}), {apex_str('delimiter for ' + repr(t))});"
    for t, w in V.DELIMITERS)

write("CsvParserTest", HEADER + f"""@IsTest
private class CsvParserTest {{
    @IsTest
    static void parsesVectors() {{
{chr(10).join(csv_cases)}
    }}

    @IsTest
    static void rejectsMalformedQuotes() {{
{csv_err}
    }}

    @IsTest
    static void detectsDelimiter() {{
{delim}
        Assert.areEqual(',', CsvParser.detectDelimiter(null), 'null defaults to comma');
    }}

    @IsTest
    static void rejectsBadDelimiter() {{
        try {{
            CsvParser.parse('a,b', ',,');
            Assert.fail('Expected CsvException');
        }} catch (CsvParser.CsvException e) {{
            Assert.isTrue(e.getMessage().contains('single character'), 'message: ' + e.getMessage());
        }}
    }}

    @IsTest
    static void parsesLargeFileWithinLimits() {{
        // 5,000 rows with quoted values: guards against quadratic scanning on the platform.
        List<String> lines = new List<String>{{ 'Trade Dt,Dealer Rep #,Fund,Amount' }};
        for (Integer i = 0; i < 5000; i++) {{
            lines.add('09/13/2026,0457,"Wealth World Fund, Series A","$1,250.00"');
        }}
        Integer cpuBefore = Limits.getCpuTime();
        List<List<String>> rows = CsvParser.parse(String.join(lines, '\\n'), ',');
        Assert.areEqual(5001, rows.size(), 'row count');
        Assert.areEqual('Wealth World Fund, Series A', rows[5000][2], 'quoted value');
        Assert.isTrue(Limits.getCpuTime() - cpuBefore < 8000, 'parse CPU ms: ' + (Limits.getCpuTime() - cpuBefore));
    }}

    private static void assertRows(String name, List<List<String>> got, List<List<String>> want) {{
        Assert.areEqual(want.size(), got.size(), name + ': row count ' + got);
        for (Integer r = 0; r < want.size(); r++) {{
            Assert.areEqual(want[r], got[r], name + ': row ' + r);
        }}
    }}

    private static void assertThrows(String text, String delimiter, String name) {{
        try {{
            CsvParser.parse(text, delimiter);
            Assert.fail(name + ': expected CsvException');
        }} catch (CsvParser.CsvException e) {{
            Assert.isNotNull(e.getMessage(), 'case: ' + name);
        }}
    }}
}}
""")

date_cases = ",\n            ".join(
    f"new List<String>{{ {apex_str(v)}, {apex_str(f)}, {apex_str(w)} }}" for v, f, w in V.DATES)
amt_cases = ",\n            ".join(
    f"new List<String>{{ {apex_str(v)}, {apex_str(s)}, {apex_str(w)} }}" for v, s, w in V.AMOUNTS)
fp_cases = []
for hs in V.FINGERPRINTS:
    fp_cases.append(
        f"        Assert.areEqual('{port.fingerprint(hs)}', MappingService.fingerprint(new List<String>{{ "
        + ", ".join(apex_str(h) for h in hs) + " }), 'fingerprint matches Python sha256');")

write("TradeRowNormalizerVectorTest", HEADER + f"""@IsTest
private class TradeRowNormalizerVectorTest {{
    @IsTest
    static void parsesDates() {{
        List<List<String>> cases = new List<List<String>>{{
            {date_cases}
        }};
        for (List<String> c : cases) {{
            List<String> errors = new List<String>();
            Date got = TradeRowNormalizer.parseDate(c[0], c[1], errors);
            if (c[2] == null) {{
                Assert.isNull(got, 'expected invalid: ' + c[0] + ' ' + c[1]);
                Assert.areEqual(1, errors.size(), 'one error for ' + c[0]);
            }} else {{
                Assert.areEqual(Date.valueOf(c[2]), got, c[0] + ' ' + c[1]);
                Assert.isTrue(errors.isEmpty(), 'no errors for ' + c[0]);
            }}
        }}
    }}

    @IsTest
    static void parsesAmounts() {{
        List<List<String>> cases = new List<List<String>>{{
            {amt_cases}
        }};
        for (List<String> c : cases) {{
            List<String> errors = new List<String>();
            Decimal got = TradeRowNormalizer.parseAmount(c[0], c[1], errors);
            if (c[2] == null) {{
                Assert.isNull(got, 'expected invalid: ' + c[0]);
                Assert.areEqual(1, errors.size(), 'one error for ' + c[0]);
            }} else {{
                Assert.areEqual(Decimal.valueOf(c[2]), got, c[0] + ' ' + c[1]);
            }}
        }}
    }}

    @IsTest
    static void normalizesRepCodes() {{
        List<List<String>> cases = new List<List<String>>{{
            {pairs(V.REP_CODES)}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(c[1], TradeRowNormalizer.normalizeRepCode(c[0]), 'rep code ' + c[0]);
        }}
        Assert.isNull(TradeRowNormalizer.normalizeRepCode('  '), 'blank code');
    }}

    @IsTest
    static void mapsTransactionTypes() {{
        List<List<String>> cases = new List<List<String>>{{
            {pairs(V.TYPES)}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(c[1], TradeRowNormalizer.TYPE_SYNONYMS.get(c[0].toUpperCase().replaceAll('[^A-Z]', '')), 'type ' + c[0]);
        }}
    }}

    @IsTest
    static void fingerprintsMatchPython() {{
{chr(10).join(fp_cases)}
    }}
}}
""")

for rn, f, l, want in V.NAME_COMPAT:
    check(f"compat {rn!r} vs {f} {l}", port.is_compatible(rn, f, l), want)
for v, want in V.FOLD_CASES:
    check(f"fold {v!r}", port.fold(v), want)
for a, b, want in V.SIMILARITY:
    from decimal import Decimal as _Dec
    check(f"sim {a!r} {b!r}", port.similarity(a, b), _Dec(want))
if fails:
    print("VECTOR FAILURES (3A):\n" + "\n".join(fails))
    sys.exit(1)
print(f"3A vectors pass ({len(V.NAME_COMPAT)} name, {len(V.FOLD_CASES)} fold, {len(V.SIMILARITY)} similarity)")

compat_rows = ",\n            ".join(
    "new List<String>{ " + ", ".join(apex_str(x) for x in (rn, f, l)) + ", '" + str(w).lower() + "' }" for rn, f, l, w in V.NAME_COMPAT)
fold_rows = ",\n            ".join(f"new List<String>{{ {apex_str(v)}, {apex_str(w)} }}" for v, w in V.FOLD_CASES)
sim_rows = ",\n            ".join(f"new List<String>{{ {apex_str(a)}, {apex_str(b)}, {apex_str(w)} }}" for a, b, w in V.SIMILARITY)
write("NameMatcherTest", HEADER + f"""@IsTest
private class NameMatcherTest {{
    @IsTest
    static void compatibilityMatchesVectors() {{
        List<List<String>> cases = new List<List<String>>{{
            {compat_rows}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(Boolean.valueOf(c[3]), NameMatcher.isCompatible(c[0], c[1], c[2]), 'compatible: ' + c[0] + ' vs ' + c[1] + ' ' + c[2]);
        }}
        Assert.isFalse(NameMatcher.isCompatible(null, 'Julia', 'Morales'), 'null row name');
        Assert.isFalse(NameMatcher.isCompatible('Julia Morales', 'Julia', null), 'null last name');
    }}

    @IsTest
    static void foldsAccentsAndPunctuation() {{
        List<List<String>> cases = new List<List<String>>{{
            {fold_rows}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(c[1], NameMatcher.fold(c[0]), 'fold: ' + c[0]);
        }}
        Assert.areEqual(new List<String>{{ 'marc', 'andre', 'roy' }}, NameMatcher.tokens('Marc-André Roy'), 'tokens');
        Assert.isTrue(NameMatcher.tokens('  ').isEmpty(), 'blank has no tokens');
    }}

    @IsTest
    static void similarityMatchesVectors() {{
        List<List<String>> cases = new List<List<String>>{{
            {sim_rows}
        }};
        for (List<String> c : cases) {{
            Assert.areEqual(Decimal.valueOf(c[2]), NameMatcher.similarity(c[0], c[1]), 'similarity: ' + c[0] + ' vs ' + c[1]);
        }}
        Assert.isTrue(NameMatcher.similarity(null, null) == 1, 'nulls compare as identical');
    }}
}}
""")
print("Apex vector tests written")
