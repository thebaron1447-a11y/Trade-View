"""Checks every shared test vector against the Python port of the Apex logic.
The same vectors are embedded in NameNormalizerTest, CsvParserTest, TradeRowNormalizerVectorTest and NameMatcherTest.
Run: python check_vectors.py"""
import sys, os
from decimal import Decimal
sys.path.insert(0, os.path.dirname(__file__))
import port, vectors as V

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
# Phase 3A: advisor name matching
for rn, f, l, want in V.NAME_COMPAT:
    check(f"compatible {rn!r} vs {f} {l}", port.is_compatible(rn, f, l), want)
for v, want in V.FOLD_CASES:
    check(f"fold {v!r}", port.fold(v), want)
for a, b, want in V.SIMILARITY:
    check(f"similarity {a!r} {b!r}", str(port.similarity(a, b)), want)

if fails:
    print("VECTOR FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print(f"all vectors pass in the Python port "
      f"({len(V.FIRM_KEYS)} keys, {len(V.DATES)} dates, {len(V.AMOUNTS)} amounts, {len(V.REP_CODES)} codes, "
      f"{len(V.TYPES)} types, {len(V.CSV) + len(V.CSV_ERRORS)} csv, {len(V.DELIMITERS)} delimiters, "
      f"{len(V.NAME_COMPAT)} names, {len(V.FOLD_CASES)} folds, {len(V.SIMILARITY)} similarities)")


