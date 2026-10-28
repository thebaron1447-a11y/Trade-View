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
    if abs(_D(str(a))) >= _D("1e16"):
        errors.append(f'Amount "{v}" is too large.')
        return None
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


# ================================================================ phase 3A: normalizer additions
def indicator_key(v):
    return re.sub(r"[^A-Z0-9]", "", (v or "").upper())


def row_type_for(by, cfg):
    if cfg.get("roster"):
        return "Code Roster"
    inds = cfg.get("aum", set())
    if not inds:
        return "Trade"
    marker = by["rowType"] if "rowType" in by else by.get("transactionType")
    return "AUM" if indicator_key(marker) in inds else "Trade"


def normalize_row3(headers, values, canonical, cfg, row_number):
    """Phase 3A normalizer: row types, AUM values, roster rows, branch."""
    errors, out = [], {"row": row_number}
    if len(values) != len(headers):
        errors.append(f"Row has {len(values)} values but the header has {len(headers)} columns.")
    by = {}
    for i in range(min(len(canonical), len(values))):
        if canonical[i] != "IGNORE":
            by[canonical[i]] = clean(values[i])
    rt = row_type_for(by, cfg)
    out["rowType"] = rt

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
    out["advisor"] = text(by.get("advisorName"), "Advisor name", 255, rt == "Code Roster")
    firm = by.get("firmName")
    if firm is None or firm.strip() == "":
        firm = cfg.get("fallbackFirm")
    out["firm"] = text(firm, "Firm name", 255, False)
    out["branch"] = text(by.get("branchName"), "Branch name", 255, False)
    out["fund"] = None
    if rt != "Code Roster":
        out["fund"] = text(by.get("fundName"), "Fund name", 255, rt == "Trade")
    label = {"Trade": "Trade date", "AUM": "As-of date", "Code Roster": "Effective date"}[rt]
    rd = by.get("tradeDate")
    out["date"] = None
    if rd is None or rd.strip() == "":
        errors.append(f"{label} is missing.")
    else:
        out["date"] = parse_date(rd, cfg["dateFormat"], errors)
    out["type"] = out["amount"] = None
    ra = by.get("amount")
    if rt == "Trade":
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
                    key = re.sub(r"[^A-Z]", "", (by.get("transactionType") or "").upper())
                    t = TYPE_SYNONYMS.get(key)
                    if t is None:
                        errors.append(f'Transaction type "{by.get("transactionType") or ""}" is not recognized as a purchase or redemption.')
                    else:
                        out["type"] = t
                    if a < 0:
                        errors.append("Amount is negative, but this source shows direction in its type column.")
                    else:
                        out["amount"] = a
    elif rt == "AUM":
        if ra is None or ra.strip() == "":
            errors.append("AUM value is missing.")
        else:
            a = parse_amount(ra, cfg["decimalSeparator"], errors)
            if a is not None:
                if a < 0:
                    errors.append("AUM value is negative.")
                else:
                    out["amount"] = a
    out["errors"] = errors
    out["status"] = "Invalid" if errors else "Pending"
    return out


CANONICAL.update({"branchName", "rowType"})


def resolve_columns3(headers, column_map, profile):
    """Mirror of MappingService.resolveColumns with feed types and AUM settings."""
    problems, cmap = [], {}
    for h, v in column_map.items():
        if v not in CANONICAL:
            problems.append(f"unknown {v}")
            continue
        cmap[header_key(h)] = v
    resolved, seen, counts = [], set(), {}
    for h in headers:
        k = header_key(h)
        if k in seen:
            problems.append("dup")
        seen.add(k)
        c = cmap.get(k)
        if c is None:
            problems.append(f"unmapped {h}")
            resolved.append("IGNORE")
            continue
        resolved.append(c)
        if c != "IGNORE":
            counts[c] = counts.get(c, 0) + 1
    problems += [f"multi {f}" for f, n in counts.items() if n > 1]
    roster = profile.get("feed") == "Advisor Code Roster"
    req = ["repCode", "advisorName", "tradeDate"] if roster else ["repCode", "fundName", "tradeDate", "amount"]
    problems += [f"missing {f}" for f in req if f not in counts]
    if not roster:
        has_type, has_row = "transactionType" in counts, "rowType" in counts
        if profile["conv"] == "Type Column" and not has_type:
            problems.append("type column needs transactionType")
        if profile["conv"] == "Signed Amount" and has_type:
            problems.append("signed forbids transactionType")
        if has_row and not profile.get("aum"):
            problems.append("rowType needs indicators")
        if profile.get("aum") and not has_row and not has_type:
            problems.append("indicators need a column")
    return resolved, problems


# ================================================================ phase 3A: NameMatcher
FOLD = {'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
        'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
        'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'œ': 'oe', 'æ': 'ae'}


def fold(v):
    if v is None:
        return ""
    s = v.lower()
    for a, b in FOLD.items():
        s = s.replace(a, b)
    return normalize_space(re.sub(r"[^a-z0-9]", " ", s))


def tokens(v):
    f = fold(v)
    return [] if f == "" else f.split(" ")


def is_compatible(row_name, first, last):
    rt, lt = tokens(row_name), tokens(last)
    if not rt or not lt:
        return False
    others = list(rt)
    for t in lt:
        if t not in others:
            return False
        others.remove(t)
    ft = tokens(first)
    if not others or not ft:
        return True
    f0 = ft[0]
    return any(t == f0 or (len(t) == 1 and f0.startswith(t)) for t in others)


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def similarity(a, b):
    from decimal import Decimal, ROUND_HALF_UP
    a, b = a or "", b or ""
    L = max(len(a), len(b))
    if L == 0:
        return Decimal(1)
    return (Decimal(L - levenshtein(a, b)) / Decimal(L)).quantize(Decimal("0.001"), rounding=ROUND_HALF_UP)


# ================================================================ phase 3A: TradeMatcher
from datetime import date as _date
from decimal import Decimal as _D
DORMANCY_DAYS, AUTO_ACCEPT, MARGIN = 180, _D("0.9"), _D("0.1")


class World:
    """Reference data, shaped like what TradeMatcher loads."""

    def __init__(self, firm_aliases, fund_aliases, rep_codes, assignments, contacts, accounts):
        self.firm_keys, self.fund_keys = {}, {}
        for key, firm in firm_aliases:
            self.firm_keys.setdefault(key, set()).add(firm)
        for key, fund in fund_aliases:
            self.fund_keys.setdefault(key, set()).add(fund)
        self.codes = {(rc["firm"], rc["name"].upper()): rc for rc in rep_codes}
        self.assign = {}
        for a in assignments:
            self.assign.setdefault(a["code"], []).append(a)
        self.contacts = contacts          # ref -> {first,last,account}
        self.accounts = accounts          # ref -> parent ref or None

    def resolve(self, key, by_key):
        exact = by_key.get(key)
        if exact and len(exact) == 1:
            return dict(id=next(iter(exact)), fuzzy=False, ambiguous=False)
        if exact:
            return dict(id=None, fuzzy=False, ambiguous=True)
        best = {}
        for ak, ids in by_key.items():
            sc = similarity(key, ak)
            for i in ids:
                if i not in best or sc > best[i]:
                    best[i] = sc
        ranked = sorted(best.items(), key=lambda kv: (-kv[1], kv[0]))
        if ranked and ranked[0][1] >= AUTO_ACCEPT and (len(ranked) == 1 or ranked[1][1] <= ranked[0][1] - MARGIN):
            return dict(id=ranked[0][0], fuzzy=True, ambiguous=False)
        return dict(id=None, fuzzy=False, ambiguous=False)

    def firm_contacts(self, firm):
        return [c for c in self.contacts.values()
                if c["account"] == firm or self.accounts.get(c["account"]) == firm]


def _active(assigns, d):
    return [a for a in assigns if a["start"] <= d and (a["end"] is None or a["end"] >= d)]


def match_row(row, w):
    """Returns (status, reason, flags, firm, code, fund, credited)."""
    flags, out = [], dict(status="Matched", reason=None, firm=None, code=None, fund=None, credited=None)

    def hold(reason, flag):
        out.update(status="Held", reason=reason)
        flags.append(flag)

    def review(flag):
        if out["status"] != "Held":
            out["status"] = "Needs Review"
        flags.append(flag)

    if row.get("firmOverride"):  # phase 3B: reviewer override (possibly an accepted Claude suggestion)
        out["firm"] = row["firmOverride"]
        flags.append("FIRM_FROM_CLAUDE" if row["firmOverride"] == row.get("aiFirm") else "FIRM_FROM_REVIEWER")
    else:
        key = firm_key(row["firm"])
        if key is None:
            review("FIRM_MISSING")
            return out, flags
        r = w.resolve(key, w.firm_keys)
        if r["id"] is None:
            review("FIRM_AMBIGUOUS" if r["ambiguous"] else "FIRM_UNRESOLVED")
            return out, flags
        out["firm"] = r["id"]
        if r["fuzzy"]:
            flags.append("FIRM_FUZZY")

    def fund():
        if row.get("fundOverride"):
            out["fund"] = row["fundOverride"]
            flags.append("FUND_FROM_CLAUDE" if row["fundOverride"] == row.get("aiFund") else "FUND_FROM_REVIEWER")
            return
        fk = firm_key(row.get("fund"))
        if fk is None:
            return
        fr = w.resolve(fk, w.fund_keys)
        if fr["id"] is None:
            review("FUND_AMBIGUOUS" if fr["ambiguous"] else "FUND_UNRESOLVED")
        else:
            out["fund"] = fr["id"]
            if fr["fuzzy"]:
                flags.append("FUND_FUZZY")

    code = w.codes.get((out["firm"], (row["repCode"] or "").upper()))
    assigns = w.assign.get(code["ref"], []) if code else []

    if row["rowType"] == "Code Roster":
        people = [ref for ref, c in w.contacts.items()
                  if (c["account"] == out["firm"] or w.accounts.get(c["account"]) == out["firm"])
                  and is_compatible(row["advisor"], c["first"], c["last"])]
        if len(people) == 1:
            out["credited"] = people[0]
        elif not people:
            flags.append("NEW_ADVISOR")
        else:
            flags.append("ADVISOR_AMBIGUOUS")
        if code is None:
            review("ROSTER_NEW_CODE")
            return out, flags
        out["code"] = code["ref"]
        for a in assigns:
            c = w.contacts[a["advisor"]]
            if a["end"] is None and is_compatible(row["advisor"], c["first"], c["last"]):
                flags.append("ROSTER_CONFIRMS")
                return out, flags
        review("ROSTER_NEW_HOLDER")
        return out, flags

    if code is None:
        hold("Unknown Code", "UNKNOWN_CODE")
        fund()
        return out, flags
    out["code"] = code["ref"]
    d = row["date"]
    active = _active(assigns, d)
    if not active:
        if any(a["end"] is not None and a["end"] < d for a in assigns):
            hold("Code Ended", "CODE_ENDED")
        else:
            review("DATE_BEFORE_CODE_START")
        fund()
        return out, flags
    name = row["advisor"]
    named = bool(name and name.strip())
    compat = [a for a in active if named and is_compatible(name, w.contacts[a["advisor"]]["first"], w.contacts[a["advisor"]]["last"])]
    team = len(active) > 1
    lasts = [a["last"] for a in active if a["last"] is not None]
    dormant = bool(lasts) and (d - max(lasts)).days > DORMANCY_DAYS
    if named and not compat:
        hold("Reassignment Suspected", "TEAM_CHANGE_SUSPECTED" if team else "REASSIGNMENT_SUSPECTED")
    elif not named and dormant:
        hold("Code Dormant", "DORMANT_CODE_NO_NAME")
    else:
        if dormant:
            flags.append("DORMANT_CODE_REACTIVATED")
        if len(compat) == 1:
            out["credited"] = compat[0]["advisor"]
            if team:
                flags.append("SINGLE_ADVISOR_CREDIT")
        elif not team:
            out["credited"] = active[0]["advisor"]
        elif sum(a["pct"] for a in active) != 100:
            hold("Allocation Incomplete", "ALLOCATION_INCOMPLETE")
        else:
            flags.append("TEAM_SPLIT")
    fund()
    return out, flags


# ================================================================ phase 3B: Claude response handling
import json as _json


class ClaudeError(Exception):
    pass


def apex_abbreviate(s, n):
    return s if len(s) <= n else s[: n - 3] + "..."


def apex_str(v):
    """String.valueOf / concatenation of a JSON value in Apex."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def is_blank(s):
    return s is None or s.strip() == ""


def parse_object(text):
    """ClaudeService.parseObject: the text from the first '{' to the last '}' as a JSON object."""
    start = -1 if text is None else text.find("{")
    finish = -1 if text is None else text.rfind("}")
    if start < 0 or finish < start:
        raise ClaudeError("The response contains no JSON object.")
    try:
        return _json.loads(text[start:finish + 1])
    except ValueError:
        raise ClaudeError("The response is not valid JSON")


CONF = {"high": "High", "medium": "Medium", "low": "Low"}
ACTIONS = {"accept", "reject", "hold"}
KEY_ASKS = ["firm", "fund", "advisor"]
MAX_EXPLANATION = 2000
MAX_HEADLINE = 100
MAX_REASON = 500
MAX_HOMEWORK = 1000


def _text(entry, name, limit, issues):
    """An optional text answer: None when absent or blank, an issue when not text."""
    v = entry.get(name)
    if v is None:
        return None
    if not isinstance(v, str):
        issues.append(f"{name} must be text.")
        return None
    return None if is_blank(v) else apex_abbreviate(v.strip(), limit)


def validate_suggestions(root, items):
    """ClaudeSuggestionService.validate (answer format 2). items: {key: {"asks": set, "allowed": {ask: set}}}.
    Returns (usable, {item: suggestion dict}, invalid set, problems list)."""
    by_item, invalid, problems = {}, set(), []
    lst = None if root is None else root.get("suggestions")
    if not isinstance(lst, list):
        return False, by_item, invalid, ["The response has no \"suggestions\" list."]
    for index, entry in enumerate(lst, start=1):
        if not isinstance(entry, dict):
            problems.append(f"Entry {index} is not an object.")
            continue
        item = entry.get("item")
        if not isinstance(item, str) or item not in items:
            problems.append(f"Entry {index} refers to an unknown item: {apex_str(item)}.")
            continue
        if item in by_item or item in invalid:
            problems.append(f"Item {item} appears more than once; only the first entry is used.")
            continue
        it, issues = items[item], []
        s = dict(item=item, firm=None, fund=None, advisor=None, fields=[], action=None, homework=None,
                 headline=None, confidence=None, explanation=None)
        fields = entry.get("fields")
        if fields is not None and not isinstance(fields, list):
            issues.append("fields must be a list.")
            fields = []
        seen = set()
        for n, f in enumerate(fields or [], start=1):
            if not isinstance(f, dict):
                issues.append(f"fields entry {n} is not an object.")
                continue
            what = f.get("field")
            if not isinstance(what, str) or what not in KEY_ASKS or what not in it["asks"]:
                continue  # fields that were not asked for are ignored, never applied
            if what in seen:
                issues.append(f"{what} appears more than once in fields.")
                continue
            seen.add(what)
            value = f.get("value")
            if value is not None and not isinstance(value, str):
                issues.append(f"{what} must be a key or null.")
                continue
            if value is not None and value not in it["allowed"][what]:
                issues.append(f"{what} \"{value}\" is not one of the candidates sent.")
                continue
            conf = f.get("confidence")
            fc = CONF.get(conf.strip().lower()) if isinstance(conf, str) else None
            if fc is None:
                issues.append(f"{what} confidence must be High, Medium or Low.")
                continue
            reason = f.get("reason")
            if not isinstance(reason, str) or is_blank(reason):
                issues.append(f"{what} reason is required.")
                continue
            s[what] = value
            s["fields"].append(dict(field=what, value=value, confidence=fc, reason=apex_abbreviate(reason.strip(), MAX_REASON)))
        s["fields"].sort(key=lambda x: KEY_ASKS.index(x["field"]))
        act = entry.get("action")
        if act is not None and "action" in it["asks"]:
            a = act.strip().lower() if isinstance(act, str) else None
            if a is None or a not in ACTIONS:
                issues.append("action must be accept, reject or hold.")
            else:
                missing = [w for w in KEY_ASKS if w in it["asks"] and s[w] is None]
                if a == "accept" and missing:
                    issues.append(f"action accept needs a {' and a '.join(missing)}.")
                else:
                    s["action"] = a
        s["homework"] = _text(entry, "homework", MAX_HOMEWORK, issues)
        s["headline"] = _text(entry, "headline", MAX_HEADLINE, issues)
        conf = entry.get("confidence")
        s["confidence"] = CONF.get(conf.strip().lower()) if isinstance(conf, str) else None
        if s["confidence"] is None:
            issues.append("confidence must be High, Medium or Low.")
        expl = entry.get("explanation")
        if not isinstance(expl, str) or is_blank(expl):
            issues.append("explanation is required.")
        else:
            s["explanation"] = apex_abbreviate(expl.strip(), MAX_EXPLANATION)
        if not issues:
            by_item[item] = s
        else:
            invalid.add(item)
            problems.extend(f"Item {item}: {i}" for i in issues)
    return True, by_item, invalid, problems


FEED_TYPES = {"Trade Activity", "Advisor Code Roster"}
DATE_FORMATS = {"MM/DD/YYYY", "DD/MM/YYYY", "YYYY-MM-DD"}
SEPARATORS = {"Period", "Comma"}
CONVENTIONS = {"Type Column", "Signed Amount"}


def _pick(root, name, allowed, problems):
    v = root.get(name)
    if isinstance(v, str) and v in allowed:
        return v
    problems.append(f"{name} must be one of: {', '.join(sorted(allowed))}.")
    return None


def validate_proposal(root, headers):
    """MappingProposalService.validate. Returns (proposal dict or None, problems)."""
    problems = []
    p = dict(feedType=_pick(root, "feedType", FEED_TYPES, problems),
             dateFormat=_pick(root, "dateFormat", DATE_FORMATS, problems),
             decimalSeparator=_pick(root, "decimalSeparator", SEPARATORS, problems),
             directionConvention=_pick(root, "directionConvention", CONVENTIONS, problems),
             aumIndicatorValues=None, confidence=None, explanation=None, columnMap={})
    aum = root.get("aumIndicatorValues")
    if aum is not None and not isinstance(aum, str):
        problems.append("aumIndicatorValues must be text or null.")
    elif aum is not None and not is_blank(aum):
        values = aum.strip()
        if len(values) > 255:
            problems.append("aumIndicatorValues is longer than 255 characters.")
        else:
            p["aumIndicatorValues"] = values
    conf = root.get("confidence")
    p["confidence"] = CONF.get(conf.strip().lower()) if isinstance(conf, str) else None
    if p["confidence"] is None:
        problems.append("confidence must be High, Medium or Low.")
    expl = root.get("explanation")
    if not isinstance(expl, str) or is_blank(expl):
        problems.append("explanation is required.")
    else:
        p["explanation"] = apex_abbreviate(expl.strip(), 3000)
    raw = root.get("columnMap")
    if not isinstance(raw, dict):
        problems.append("columnMap must be an object of \"column header\": \"field\".")
        return None, problems
    header_by_key = {header_key(h): h for h in headers}
    mapped, bad = set(), set()
    for given, field in raw.items():
        key = header_key(given)
        if key not in header_by_key:
            problems.append(f"columnMap names a column that is not in the file: \"{given}\".")
        elif key in mapped or key in bad:
            problems.append(f"Column \"{header_by_key[key]}\" is mapped more than once.")
        elif not isinstance(field, str) or field not in CANONICAL:
            bad.add(key)
            problems.append(f"Column \"{header_by_key[key]}\" is mapped to {apex_str(field)}, which is not a known field.")
        else:
            mapped.add(key)
            p["columnMap"][header_by_key[key]] = field
    for h in headers:
        key = header_key(h)
        if key not in mapped and key not in bad:
            problems.append(f"Column \"{h}\" has no mapping.")
            bad.add(key)
    return (p if not problems else None), problems


# ---------------------------------------------------------------- 3B.2: reviewer-facing explanation text
_KEY = r"[FPARU][0-9]+"
_SPACE = r"[ \t\r\n]*"
_BRACKETED = re.compile(_SPACE + r"\(" + _SPACE + "(" + _KEY + "(?:" + _SPACE + "(?:,|/|and|or)" + _SPACE + _KEY + ")*)" + _SPACE + r"\)")
_BARE = re.compile(r"(?<![A-Za-z0-9_])" + _KEY + r"(?![A-Za-z0-9_])")

def _blank(s):
    return s is None or s.strip() == ""

def readable(text, name_by_key):
    """Mirror of ClaudeSuggestionService.readable."""
    if _blank(text) or not name_by_key:
        return text
    def bracket(m):
        for k in _BARE.findall(m.group(1)):
            if _blank(name_by_key.get(k)):
                return m.group(0)
        return ""
    def bare(m):
        name = name_by_key.get(m.group(0))
        return m.group(0) if _blank(name) else name
    out = _BRACKETED.sub(bracket, text)
    out = _BARE.sub(bare, out)
    return apex_abbreviate(out.strip("".join(chr(i) for i in range(33))), MAX_EXPLANATION)  # Apex trim()
