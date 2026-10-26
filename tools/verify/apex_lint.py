"""Apex runtime pitfalls that parse and pass static analysis but fail on the platform.
Added after the phase 2 org gate found two such failures.

1. Assert messages that can be null. Apex's Assert methods throw NullPointerException
   ("Message parameter cannot be null") when the message argument is null, which turns a
   passing assertion into a failure. A message is accepted only if it contains a string
   literal, because 'label: ' + null is 'label: null' while String.valueOf(null) is null.
3. Files that start with a UTF-8 byte order mark (Windows PowerShell 5 adds one with -Encoding utf8);
   Apex fails to compile them with "Invalid identifier ''" at line 1.
2. String.isBlank / isNotBlank on whitespace-significant values. isBlank('\t') is true, so a
   tab delimiter was rejected as blank. Flags isBlank on names containing delim/separator/token.
"""
import glob, re, sys

files = sys.argv[1:] or glob.glob("/home/claude/build/force-app/main/default/classes/*.cls")
problems = []


def split_args(s):
    """Split a call's argument string on top-level commas."""
    args, depth, cur, q = [], 0, "", False
    i = 0
    while i < len(s):
        c = s[i]
        if q:
            cur += c
            if c == "\\":
                cur += s[i + 1]
                i += 1
            elif c == "'":
                q = False
        elif c == "'":
            q = True
            cur += c
        elif re.match(r"(Map|List|Set)\s*<", s[i:]) and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] == "_")):
            # Generic type arguments (Map<String, String>) contain commas that do not separate arguments.
            j, angle = s.index("<", i), 0
            while j < len(s):
                angle += {"<": 1, ">": -1}.get(s[j], 0)
                j += 1
                if angle == 0:
                    break
            cur += s[i:j]
            i = j
            continue
        elif c in "([{":
            depth += 1
            cur += c
        elif c in ")]}":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        args.append(cur.strip())
    return args


def calls(code, prefix):
    """Yield (line, argument string) for each prefix(...) call, matching parentheses."""
    for m in re.finditer(re.escape(prefix) + r"\(", code):
        start = m.end()
        depth, i, q = 1, start, False
        while i < len(code) and depth:
            c = code[i]
            if q:
                if c == "\\":
                    i += 1
                elif c == "'":
                    q = False
            elif c == "'":
                q = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        yield code.count("\n", 0, m.start()) + 1, code[start:i - 1]


MESSAGE_POS = {"areEqual": 2, "areNotEqual": 2, "isTrue": 1, "isFalse": 1, "isNull": 1, "isNotNull": 1,
               "isInstanceOfType": 2, "isNotInstanceOfType": 2, "fail": 0}
BARE_REF = re.compile(r"^[A-Za-z_][\w]*(?:\[[^\]]*\])?(?:\.[A-Za-z_]\w*(?:\[[^\]]*\])?)*$")

for path in files:
    raw = open(path, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{path.split('/')[-1]}:1 starts with a byte order mark; Apex rejects it (Invalid identifier '')")
    code = raw.decode("utf-8-sig")
    code = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), code)
    name = path.split("/")[-1]
    for method, pos in MESSAGE_POS.items():
        for line, argstr in calls(code, "Assert." + method):
            args = split_args(argstr)
            if len(args) > pos:
                msg = args[pos]
                # Safe only if the message contains a string literal: 'text' + x is never null in Apex.
                # String.valueOf(null) returns null in Apex (unlike Java), so it does not make a message safe.
                if "'" not in msg:
                    problems.append(f"{name}:{line} Assert.{method} message `{msg}` can be null; use 'label: ' + value")
    for line, argstr in list(calls(code, "String.isBlank")) + list(calls(code, "String.isNotBlank")):
        if re.search(r"(?i)delim|separator|token", argstr):
            problems.append(f"{name}:{line} String.isBlank({argstr}) treats tab and space as blank; compare to null instead")

# 4. Identifiers Apex rejects at compile time: ending with an underscore, or containing "__" other than the
#    custom suffixes (__c, __r, __mdt, __e, __x, __b, __Share, __History). Added after the 3B org gate (list_).
SUFFIX = re.compile(r"__(c|r|mdt|e|x|b|Share|History|Feed)$")
for f in files:
    raw = open(f, encoding="utf-8").read()
    # Comments and strings are blanked but their line breaks kept, so reported line numbers stay right.
    code = re.sub(r"//[^\n]*|/\*.*?\*/|'(?:\\.|[^'\\])*'",
                  lambda m: "''" if m.group(0).startswith("'") else "\n" * m.group(0).count("\n"), raw, flags=re.S)
    for lineno, line in enumerate(code.split("\n"), start=1):
        for ident in re.findall(r"(?<![\w.])([A-Za-z_]\w*)", line):
            base = SUFFIX.sub("", ident)
            if base.endswith("_") or "__" in base:
                problems.append(f"{f.split('/')[-1]}:{lineno} identifier `{ident}` is not valid Apex (trailing or double underscore)")

# Reserved words cannot name a variable or parameter (the org rejects `Map<String, Object> system = ...` with
# "Identifier name is reserved"). Checked on declarations only, outside strings and SOQL keywords (which are upper case).
RESERVED = set("""abstract activate and any array as asc autonomous begin bigdecimal blob break bulk by byte case cast catch
char class collect commit const continue convertcurrency decimal default delete desc do else end enum exception exit export
extends false final finally float for from future global goto group having hint if implements import in inner insert
instanceof interface into int join like limit list long loop map merge new not null nulls number object of on or outer
override package parallel pragma private protected public retrieve return returning rollback savepoint search select set
short sort stat static super switch synchronized system testmethod then this throw today tolabel tomorrow transaction trigger
true try undelete update upsert using virtual webservice when where while yesterday""".split())
DECL = re.compile(r"(?:^|[\s(,])[A-Z]\w*(?:<[^;=()]*?>)?(?:\[\])?\s+([a-z]\w*)\s*(?:=|;|,|\)|:)")
for f in files:
    for lineno, line in enumerate(open(f, encoding="utf-8-sig"), 1):
        code = re.sub(r"'(?:\\.|[^'])*'", "''", line.split("//")[0])
        if code.strip().startswith(("*", "/*")):
            continue
        for m in DECL.finditer(code):
            if m.group(1) in RESERVED:
                problems.append(f"{f.split('/')[-1]}:{lineno} `{m.group(1)}` is a reserved word in Apex and cannot name a variable")
# SOQL rejects ORDER BY in a query that locks rows (FOR UPDATE); the local parser accepts it.
for f in files:
    text = open(f, encoding="utf-8-sig").read()
    for m in re.finditer(r"\[\s*SELECT\b.*?\]", text, re.S | re.I):
        q = m.group(0)
        if re.search(r"\bFOR\s+UPDATE\b", q, re.I) and re.search(r"\bORDER\s+BY\b", q, re.I):
            line = text[: m.start()].count("\n") + 1
            problems.append(f"{f.split('/')[-1]}:{line} SOQL with FOR UPDATE cannot use ORDER BY")
print("\n".join(problems) if problems else f"apex lint: no problems in {len(files)} files")
sys.exit(1 if problems else 0)
