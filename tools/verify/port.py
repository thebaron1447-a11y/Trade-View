"""Python port of the phase 2 Apex logic, used to verify test vectors and sample files.
Mirrors NameNormalizer, CsvParser, MappingService.headerKey/fingerprint and TradeRowNormalizer."""
import hashlib, json, re, calendar
from datetime import date

NBSP, NNBSP, BOM = " ", " ", "﻿"

# ---------------------------------------------------------------- NameNormalizer
SUFFIXES = ['and company', 'and co', 'and c', 'et compagnie', 'et cie',
            'incorporated', 'corporation', 'limited', 'company', 'compagnie',
            'corp', 'inc', 'ltd', 'ltée', 'ltee', 'llp', 'lp', 'cie', 'co', 'and', 'et']


def normalize_space(s):
    return " ".join(s.split())


def firm_key(raw):
    if raw is None or raw.strip() == "":
        return None
    s = raw.lower().replace("&", " and ")
    s = "".join(c if (c.isalpha() or c.isdigit() or c == " ") else " " for c in s)
    s = normalize_space(s)
    stripped = True
    while stripped:
        stripped = False
        for suf in SUFFIXES:
            if s.endswith(" " + suf):
                s = normalize_space(s[: -len(" " + suf)])
                stripped = True
                break
    return s or None


# ---------------------------------------------------------------- CsvParser
class CsvError(Exception):
    pass


def detect_delimiter(raw):
    if raw is None or raw.strip() == "":
        return ","
    commas = semis = tabs = 0
    in_q = False
    for c in raw:
        if c == '"':
            in_q = not in_q
        elif not in_q:
            if c in "\r\n":
                break
            if c == ",":
                commas += 1
            elif c == ";":
                semis += 1
            elif c == "\t":
                tabs += 1
    if semis > commas and semis >= tabs:
        return ";"
    if tabs > commas and tabs > semis:
        return "\t"
    return ","


def parse_csv(raw, delim):
    if raw is None or raw.strip() == "":
        return []
    if delim is None or len(delim) != 1:
        raise CsvError("Delimiter must be a single character.")
    text = raw[1:] if raw.startswith(BOM) else raw
    n = len(text)
    rows, row, i, line = [], [], 0, 1

    def add(r):
        if any(v.strip() for v in r):
            rows.append(r)

    while True:
        if i < n and text[i] == '"':
            parts, j = [], i + 1
            while True:
                q = text.find('"', j)
                if q == -1:
                    raise CsvError(f"Unclosed quoted value starting on line {line}.")
                parts.append(text[j:q])
                if q + 1 < n and text[q + 1] == '"':
                    parts.append('"')
                    j = q + 2
                else:
                    i = q + 1
                    break
            value = "".join(parts)
        else:
            cands = [p for p in (text.find(delim, i), text.find("\n", i), text.find("\r", i)) if p != -1]
            stop = min(cands) if cands else n
            value = text[i:stop]
            i = stop
        row.append(value)
        if i >= n:
            add(row)
            break
        c = text[i]
        if c == delim:
            i += 1
            continue
        if c == "\r":
            i += 1
            if i < n and text[i] == "\n":
                i += 1
        elif c == "\n":
            i += 1
        else:
            raise CsvError(f"Unexpected text after a quoted value on line {line}.")
        add(row)
        row = []
        line += 1
        if i >= n:
            break
    return rows


# ---------------------------------------------------------------- MappingService
def header_key(h):
    return "" if h is None else normalize_space(h.replace(NBSP, " ").strip().lower())


def fingerprint(headers):
    return hashlib.sha256("|".join(header_key(h) for h in headers).encode("utf-8")).hexdigest()


CANONICAL = {"repCode", "advisorName", "firmName", "fundName", "tradeDate", "amount", "transactionType", "IGNORE"}
REQUIRED = ["repCode", "fundName", "tradeDate", "amount"]


def resolve_columns(headers, column_map, convention):
    problems, cmap = [], {}
    for h, v in column_map.items():
        if v not in CANONICAL:
            problems.append(f'Column "{h}" mapped to unknown {v}')
            continue
        cmap[header_key(h)] = v
    resolved, seen, counts = [], set(), {}
    for h in headers:
        k = header_key(h)
        if k in seen:
            problems.append(f'duplicate column {h}')
        seen.add(k)
        c = cmap.get(k)
        if c is None:
            problems.append(f'Column "{h}" is not mapped')
            resolved.append("IGNORE")
            continue
        resolved.append(c)
        if c != "IGNORE":
            counts[c] = counts.get(c, 0) + 1
    problems += [f"more than one column mapped to {f}" for f, n in counts.items() if n > 1]
    problems += [f"no column mapped to {f}" for f in REQUIRED if f not in counts]
    if convention == "Type Column" and "transactionType" not in counts:
        problems.append("Type Column needs transactionType")
    if convention == "Signed Amount" and "transactionType" in counts:
        problems.append("Signed Amount forbids transactionType")
    return resolved, problems


# ---------------------------------------------------------------- TradeRowNormalizer
TYPE_SYNONYMS = {k: "Purchase" for k in ["BUY", "B", "P", "PURCHASE", "PURCH", "PUR", "SUBSCRIPTION", "SUB", "ACHAT"]}
TYPE_SYNONYMS.update({k: "Redemption" for k in ["SELL", "S", "R", "REDEMPTION", "RED", "REDEEM", "REDEMP", "VENTE", "RACHAT"]})
YMD = re.compile(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?$", re.ASCII)
DMY = re.compile(r"^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?$", re.ASCII)
PLAIN = re.compile(r"^\d+(\.\d+)?$", re.ASCII)


def normalize_rep_code(v):
    if v is None or v.strip() == "":
        return None
    code = "".join(v.split()).upper()
    if code.isdigit():
        code = re.sub(r"^0+(?=\d)", "", code)
    return code


def parse_date(v, fmt, errors):
    y = m = d = None
    if fmt == "YYYY-MM-DD":
        mt = YMD.match(v)
        if mt:
            y, m, d = int(mt[1]), int(mt[2]), int(mt[3])
    elif fmt in ("MM/DD/YYYY", "DD/MM/YYYY"):
        mt = DMY.match(v)
        if mt:
            mf = fmt == "MM/DD/YYYY"
            m, d, y = int(mt[1 if mf else 2]), int(mt[2 if mf else 1]), int(mt[3])
    else:
        errors.append("no valid date format")
        return None
    if y is None:
        errors.append(f'Trade date "{v}" does not match the format {fmt}.')
        return None
    if y < 1990 or y > 2100 or m < 1 or m > 12 or d < 1 or d > calendar.monthrange(y, m)[1]:
        errors.append(f'Trade date "{v}" is not a valid date in the format {fmt}.')
        return None
    return date(y, m, d)


def round_half_up(s):
    from decimal import Decimal, ROUND_HALF_UP
    return Decimal(s).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def parse_amount(v, sep, errors):
    s = v.replace(NBSP, " ").replace(NNBSP, " ").strip()
    s = re.sub(r"(?i)\b(CAD|USD)\b", "", s).replace("$", "").strip()
    neg = False
    if s.startswith("(") and s.endswith(")"):
        neg, s = True, s[1:-1].strip()
    if s.startswith("-"):
        neg, s = not neg, s[1:].strip()
    elif s.endswith("-"):
        neg, s = not neg, s[:-1].strip()
    if sep == "Comma":
        s = s.replace(".", "").replace(" ", "").replace("'", "").replace(",", ".")
    else:
        s = s.replace(",", "").replace(" ", "").replace("'", "")
    if not PLAIN.match(s):
        errors.append(f'Amount "{v}" is not a number.')
        return None
    a = round_half_up(s)
    return -a if neg else a


def clean(v):
    return None if v is None else normalize_space(v.replace(NBSP, " ").replace(NNBSP, " "))


def normalize_row(headers, values, canonical, cfg, row_number):
    errors, out = [], {"row": row_number}
    if len(values) != len(headers):
        errors.append(f"Row has {len(values)} values but the header has {len(headers)} columns.")
    by = {}
    for i in range(min(len(canonical), len(values))):
        if canonical[i] != "IGNORE":
            by[canonical[i]] = clean(values[i])

    def text(val, label, mx, req):
        if val is None or val.strip() == "":
            if req:
                errors.append(f"{label} is missing.")
            return None
        if len(val) > mx:
            errors.append(f"{label} too long")
            return val[:mx]
        return val

    out["repCode"] = text(normalize_rep_code(by.get("repCode")), "Rep code", 40, True)
    out["advisor"] = text(by.get("advisorName"), "Advisor name", 255, False)
    firm = by.get("firmName")
    if firm is None or firm.strip() == "":
        firm = cfg.get("fallbackFirm")
    out["firm"] = text(firm, "Firm name", 255, False)
    out["fund"] = text(by.get("fundName"), "Fund name", 255, True)
    rd = by.get("tradeDate")
    out["date"] = None
    if rd is None or rd.strip() == "":
        errors.append("Trade date is missing.")
    else:
        out["date"] = parse_date(rd, cfg["dateFormat"], errors)
    out["type"] = out["amount"] = None
    ra = by.get("amount")
    if ra is None or ra.strip() == "":
        errors.append("Amount is missing.")
    else:
        a = parse_amount(ra, cfg["decimalSeparator"], errors)
        if a is not None:
            if a == 0:
                errors.append("Amount is zero.")
            elif cfg["direction"] == "Signed Amount":
                out["type"] = "Redemption" if a < 0 else "Purchase"
                out["amount"] = abs(a)
            else:
                rt = by.get("transactionType")
                key = re.sub(r"[^A-Z]", "", (rt or "").upper())
                t = TYPE_SYNONYMS.get(key)
                if t is None:
                    errors.append(f'Transaction type "{rt or ""}" is not recognized as a purchase or redemption.')
                else:
                    out["type"] = t
                if a < 0:
                    errors.append("Amount is negative, but this source shows direction in its type column.")
                else:
                    out["amount"] = a
    out["errors"] = errors
    return out
