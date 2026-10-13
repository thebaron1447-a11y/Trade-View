"""Shared test vectors. Each is checked against the Python port here and emitted into Apex tests."""
NNBSP = " "

FIRM_KEYS = [
    ("Barder & Company", "barder"),
    ("Barder and Co", "barder"),
    ("Barder and C.", "barder"),
    ("Barder & Co., Inc.", "barder"),
    ("BARDER AND COMPANY", "barder"),
    ("Co", "co"),
    ("Lumière Valeurs Mobilières Ltée", "lumière valeurs mobilières"),
    ("Lumiere Valeurs Mobilieres", "lumiere valeurs mobilieres"),
    ("Kestrel Capital Inc.", "kestrel capital"),
    ("Kestrel Capital Ltd.", "kestrel capital"),
    ("Northgate WP", "northgate wp"),
    ("Smith Corp., Ltd.", "smith"),
    ("A.B.C. Securities Inc", "a b c securities"),
    ("Fontaine et Cie", "fontaine"),
    ("Wealth World Fund - Series A", "wealth world fund series a"),
    ("   ", None),
    ("!!!", None),
]

DATES = [  # (value, format, expected ISO date or None)
    ("09/13/2026", "MM/DD/YYYY", "2026-09-13"),
    ("13/09/2026", "DD/MM/YYYY", "2026-09-13"),
    ("13/09/2026", "MM/DD/YYYY", None),
    ("03/04/2026", "MM/DD/YYYY", "2026-03-04"),
    ("03/04/2026", "DD/MM/YYYY", "2026-04-03"),
    ("2026-09-13", "YYYY-MM-DD", "2026-09-13"),
    ("2026-9-3", "YYYY-MM-DD", "2026-09-03"),
    ("31/09/2026", "DD/MM/YYYY", None),
    ("02/29/2024", "MM/DD/YYYY", "2024-02-29"),
    ("02/29/2026", "MM/DD/YYYY", None),
    ("09-13-2026", "MM/DD/YYYY", "2026-09-13"),
    ("13.09.2026", "DD/MM/YYYY", "2026-09-13"),
    ("2026-09-13T00:00:00", "YYYY-MM-DD", "2026-09-13"),
    ("09/13/2026 14:30", "MM/DD/YYYY", "2026-09-13"),
    ("Sept 13 2026", "MM/DD/YYYY", None),
    ("09/13/26", "MM/DD/YYYY", None),
    ("01/01/1899", "MM/DD/YYYY", None),
    ("2026-13-01", "YYYY-MM-DD", None),
]

AMOUNTS = [  # (value, decimal separator, expected string or None)
    ("$1,250.00", "Period", "1250.00"),
    ("-$1,250.00", "Period", "-1250.00"),
    ("$-1,250.00", "Period", "-1250.00"),
    ("(1,250.50)", "Period", "-1250.50"),
    ("1250.5", "Period", "1250.50"),
    ("CAD 400,000", "Period", "400000.00"),
    ("250-", "Period", "-250.00"),
    ("1,234.567", "Period", "1234.57"),
    ("12 500,00", "Comma", "12500.00"),
    ("12" + NNBSP + "500,00", "Comma", "12500.00"),
    ("1.234,56", "Comma", "1234.56"),
    ("-3 000,5", "Comma", "-3000.50"),
    ("abc", "Period", None),
    ("1,2,3.4.5", "Period", None),
    ("$", "Period", None),
]

REP_CODES = [
    ("0457", "457"),
    (" 457 ", "457"),
    ("000", "0"),
    ("ab-12", "AB-12"),
    ("0A12", "0A12"),
    ("00 12", "12"),
]

TYPES = [
    ("Buy", "Purchase"), ("SELL", "Redemption"), ("Achat", "Purchase"), ("RACHAT", "Redemption"),
    ("P", "Purchase"), ("R", "Redemption"), ("Sub.", "Purchase"), ("Exchange", None),
]

CSV = [  # (name, text, delimiter, expected rows)
    ("simple", "a,b\n1,2\n", ",", [["a", "b"], ["1", "2"]]),
    ("crlf", "a,b\r\n1,2", ",", [["a", "b"], ["1", "2"]]),
    ("quoted comma", '"x, y",z\n', ",", [["x, y", "z"]]),
    ("escaped quote", '"he said ""hi""",2', ",", [['he said "hi"', "2"]]),
    ("newline in quotes", '"line1\nline2",3', ",", [["line1\nline2", "3"]]),
    ("bom", "﻿a,b", ",", [["a", "b"]]),
    ("blank lines skipped", "a,b\n\n1,2\n,\n", ",", [["a", "b"], ["1", "2"]]),
    ("trailing delimiter", "a,b,\n", ",", [["a", "b", ""]]),
    ("semicolon", "a;b\n1,5;2", ";", [["a", "b"], ["1,5", "2"]]),
    ("tab", "a\tb\n1\t2", "\t", [["a", "b"], ["1", "2"]]),
    ("space delimiter", "a b\n1 2", " ", [["a", "b"], ["1", "2"]]),
    ("empty", "", ",", []),
]
CSV_ERRORS = [("unclosed quote", '"abc,1', ","), ("text after quote", '"a"b,1', ","),
              ("two-character delimiter", "a,b", ",,"), ("empty delimiter", "a,b", "")]

DELIMITERS = [
    ("a;b;c\n1,2;3", ";"), ("a,b\n", ","), ('"x;y",b', ","), ("a\tb\tc", "\t"), ("abc", ","),
]

FINGERPRINTS = [  # header lists whose SHA-256 the Apex test must reproduce exactly
    ["Trade Dt", "Dealer Rep #", "Gross Amt"],
    ["  Date de transaction ", "Code représentant", "MONTANT"],
]
