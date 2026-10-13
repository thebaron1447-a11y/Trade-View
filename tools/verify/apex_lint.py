"""Apex runtime pitfalls that parse and pass static analysis but fail on the platform.
Added after the phase 2 org gate found two such failures.

1. Assert messages that can be null. Apex's Assert methods throw NullPointerException
   ("Message parameter cannot be null") when the message argument is null, which turns a
   passing assertion into a failure. A message is accepted only if it contains a string
   literal, because 'label: ' + null is 'label: null' while String.valueOf(null) is null.
2. String.isBlank / isNotBlank on whitespace-significant values. isBlank('\t') is true, so a
   tab delimiter was rejected as blank. Flags isBlank on names containing delim/separator/token.
"""
import glob, re, sys

files = sys.argv[1:] or glob.glob("../../force-app/main/default/classes/*.cls")
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
    code = open(path, encoding="utf-8").read()
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

print("\n".join(problems) if problems else f"apex lint: no problems in {len(files)} files")
sys.exit(1 if problems else 0)
