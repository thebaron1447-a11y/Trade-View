"""Cross-reference check: every custom object/field referenced in Apex, SOQL, the seed script, layouts,
list views and permission sets must exist in the project metadata, on the right object."""
import glob, os, re, sys
import xml.etree.ElementTree as ET

ROOT = "/home/claude/build/force-app/main/default"
NS = {"m": "http://soap.sforce.com/2006/04/metadata"}
problems = []

# ---------------------------------------------------------------- inventory
fields = {}      # object -> {field: element}
for obj_dir in glob.glob(f"{ROOT}/objects/*"):
    obj = os.path.basename(obj_dir)
    fields[obj] = {}
    for fp in glob.glob(f"{obj_dir}/fields/*.field-meta.xml"):
        el = ET.parse(fp).getroot()
        fields[obj][el.find("m:fullName", NS).text] = el
objects = set(fields)
STANDARD_FIELDS = {"Id", "Name", "OwnerId", "CreatedDate", "CreatedById", "LastModifiedById", "SystemModstamp"}
STANDARD_OBJECTS = {"Account", "Contact", "Product2", "ContentVersion", "ContentDocument", "ContentDocumentLink", "User", "Profile",
                    "PermissionSet", "PermissionSetAssignment"}
all_custom_fields = {f for fs in fields.values() for f in fs}
# child relationship name (Assignments__r) -> child object, from each lookup/master-detail's relationshipName
child_rels = {}
for _obj, _fs in fields.items():
    for _el in _fs.values():
        _rn = _el.find("m:relationshipName", NS)
        if _rn is not None:
            child_rels[_rn.text + "__r"] = _obj


def balanced_args(text, start):
    """Text between the '(' at start and its matching ')'."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return text[start + 1:]


def ref_to(obj, fld):
    el = fields.get(obj, {}).get(fld)
    r = el.find("m:referenceTo", NS) if el is not None else None
    return r.text if r is not None else None


def check_path(obj, path, where):
    """Check Field__c or Rel__r.Field paths on obj."""
    parts = path.split(".")
    cur = obj
    for i, p in enumerate(parts):
        last = i == len(parts) - 1
        if p.endswith("__r"):
            f = p[:-3] + "__c"
            if cur in fields and f not in fields[cur]:
                problems.append(f"{where}: {cur} has no field {f} (for {p})")
                return
            cur = ref_to(cur, f) or "?"
        elif p.endswith("__c"):
            if cur in fields and p not in fields[cur]:
                problems.append(f"{where}: {cur} has no field {p}")
            if not last:
                problems.append(f"{where}: {p} used as a relationship")
        # standard names are not checked in detail


# ---------------------------------------------------------------- Apex + seed script
sources = glob.glob(f"{ROOT}/classes/*.cls") + glob.glob(f"{ROOT}/triggers/*.trigger") + \
          glob.glob("/home/claude/build/scripts/apex/*.apex")
for src in sources:
    name = os.path.basename(src)
    code = open(src, encoding="utf-8").read()
    # Strip comments and string literals in one left-to-right pass (an apostrophe in a comment is not a string).
    code_nostr = re.sub(r"//[^\n]*|/\*.*?\*/|'(?:\\.|[^'\\])*'",
                        lambda m: "''" if m.group(0).startswith("'") else " ", code, flags=re.S)
    code = re.sub(r"//[^\n]*|/\*.*?\*/", " ", code, flags=re.S)
    # every token must exist as an object or a field somewhere
    for tok in set(re.findall(r"\b([A-Za-z0-9_]+__c)\b", code_nostr)):
        if tok not in objects and tok not in all_custom_fields:
            problems.append(f"{name}: unknown custom name {tok}")
    for tok in set(re.findall(r"\b([A-Za-z0-9_]+__r)\b", code_nostr)):
        if tok[:-3] + "__c" not in all_custom_fields and tok not in child_rels:
            problems.append(f"{name}: unknown relationship {tok}")
    # SOQL: fields must exist on the FROM object
    for q in re.findall(r"\[\s*SELECT(.*?)\]", code, flags=re.S | re.I):
        om = re.search(r"\bFROM\s+(\w+)", re.sub(r"\(\s*SELECT.*?\)", " ", q, flags=re.S | re.I), flags=re.I)
        outer = om.group(1) if om else "?"
        for sub_sel, rel in re.findall(r"\(\s*SELECT(.*?)\bFROM\s+(\w+__r)", q, flags=re.S | re.I):
            if rel not in child_rels:
                problems.append(f"{name}: subquery on unknown child relationship {rel}")
            elif outer in objects or outer in STANDARD_OBJECTS:
                parent = ref_to(child_rels[rel], [f for f, e in fields[child_rels[rel]].items()
                                                  if e.find("m:relationshipName", NS) is not None
                                                  and e.find("m:relationshipName", NS).text + "__r" == rel][0])
                if parent != outer:
                    problems.append(f"{name}: {rel} is a child of {parent}, not {outer}")
            for path in re.findall(r"\b([A-Za-z0-9_]+(?:__[cr])(?:\.[A-Za-z0-9_]+)*)\b", sub_sel):
                check_path(child_rels.get(rel, "?"), path, f"{name} subquery {rel}")
        q = re.sub(r"\(\s*SELECT.*?\)", " ", q, flags=re.S | re.I)
        m = re.match(r"(.*?)\bFROM\s+(\w+)(.*)", q, flags=re.S | re.I)
        if not m:
            continue
        sel, obj, rest = m.groups()
        if obj not in objects and obj not in STANDARD_OBJECTS:
            problems.append(f"{name}: SOQL FROM unknown object {obj}")
        for path in re.findall(r"\b([A-Za-z0-9_]+(?:__[cr])(?:\.[A-Za-z0-9_]+)*)\b", sel + " " + rest):
            if obj in objects or path.split(".")[0].endswith(("__c", "__r")):
                check_path(obj, path, f"{name} SOQL on {obj}")
    # User-mode DML on records taken straight from a query: Salesforce checks edit access on every populated
    # field, so selecting a field that can never be edited (master-detail that is not reparentable, formula,
    # roll-up, auto-number) makes the whole update fail with "fields being inaccessible" (phase 3A org gate).
    queried = {}
    for qm in re.finditer(r"(\w+)\s*=\s*\[\s*SELECT(.*?)\bFROM\s+(\w+)", code, flags=re.S | re.I):
        queried[qm.group(1)] = (qm.group(3), qm.group(2))
    for qm in re.finditer(r"for\s*\(\s*\w+\s+(\w+)\s*:\s*\[\s*SELECT(.*?)\bFROM\s+(\w+)", code, flags=re.S | re.I):
        queried[qm.group(1)] = (qm.group(3), qm.group(2))
    for dm in re.finditer(r"\b(update|upsert)\s+as\s+user\s+(\w+)\s*;", code):
        var = dm.group(2)
        if var not in queried:
            continue
        obj, sel = queried[var]
        sel = re.sub(r"\(\s*SELECT.*?\)", " ", sel, flags=re.S | re.I)
        for fld in re.findall(r"(?<![.\w])(\w+__c)\b(?!\.)", sel):
            el = fields.get(obj, {}).get(fld)
            if el is None:
                continue
            kind = el.find("m:type", NS).text
            reparent = el.find("m:reparentableMasterDetail", NS)
            if (kind == "MasterDetail" and (reparent is None or reparent.text != "true")) or kind in ("Summary", "AutoNumber") \
                    or el.find("m:formula", NS) is not None:
                problems.append(f"{name}: '{dm.group(1)} as user {var}' sends queried field {obj}.{fld} ({kind}), "
                                f"which can never be edited; update a fresh record with only the changed fields")
    # new Obj__c(Field__c = ...) constructors
    for cm in re.finditer(r"new\s+(\w+__c)\s*\(", code_nostr):
        obj, args = cm.group(1), balanced_args(code_nostr, cm.end() - 1)
        for fld in re.findall(r"\b(\w+__c)\s*=", args):
            check_path(obj, fld, f"{name} new {obj}()")

# ---------------------------------------------------------------- layouts / list views / permission sets
for fp in glob.glob(f"{ROOT}/layouts/*.layout-meta.xml"):
    obj = os.path.basename(fp).split("-")[0]
    root = ET.parse(fp).getroot()
    for f in root.iterfind(".//m:layoutItems/m:field", NS):
        if f.text.endswith("__c"):
            check_path(obj, f.text, f"layout {obj}")
    for rl in root.iterfind(".//m:relatedLists", NS):
        child, fk = rl.find("m:relatedList", NS).text.split(".")
        check_path(child, fk, f"related list on {obj}")
        if ref_to(child, fk) != obj:
            problems.append(f"related list {child}.{fk} does not point at {obj}")
        for c in rl.iterfind("m:fields", NS):
            if c.text.endswith("__c"):
                check_path(child, c.text, f"related list columns {child}")
for fp in glob.glob(f"{ROOT}/objects/*/listViews/*.xml"):
    obj = fp.split("/objects/")[1].split("/")[0]
    for c in ET.parse(fp).getroot().iterfind("m:columns", NS):
        if c.text.endswith("__c"):
            check_path(obj, c.text, f"list view {obj}")
for fp in glob.glob(f"{ROOT}/permissionsets/*.xml"):
    root = ET.parse(fp).getroot()
    ps = os.path.basename(fp)
    for f in root.iterfind("m:fieldPermissions/m:field", NS):
        obj, fld = f.text.split(".")
        check_path(obj, fld, ps)
        el = fields.get(obj, {}).get(fld)
        if el is not None:
            req = el.find("m:required", NS)
            if (req is not None and req.text == "true") or el.find("m:type", NS).text == "MasterDetail":
                problems.append(f"{ps}: field permission on required/master-detail field {f.text}")
    for c in root.iterfind("m:classAccesses/m:apexClass", NS):
        if not os.path.exists(f"{ROOT}/classes/{c.text}.cls"):
            problems.append(f"{ps}: class {c.text} not in project")
    granted = {f.text for f in root.iterfind("m:fieldPermissions/m:field", NS)}
    objs = {o.text for o in root.iterfind("m:objectPermissions/m:object", NS)}
    for obj in objs:
        for fld, el in fields.get(obj, {}).items():
            req = el.find("m:required", NS)
            optional = not (req is not None and req.text == "true") and el.find("m:type", NS).text != "MasterDetail"
            if optional and f"{obj}.{fld}" not in granted:
                problems.append(f"{ps}: no field permission for {obj}.{fld}")

# ---------------------------------------------------------------- known platform restrictions
for obj, fs in fields.items():
    for fld, el in fs.items():
        t = el.find("m:type", NS).text
        ref = el.find("m:referenceTo", NS)
        if t == "Lookup" and ref is not None and ref.text == "Product2":
            dc = el.find("m:deleteConstraint", NS)
            req = el.find("m:required", NS)
            if (dc is not None and dc.text != "SetNull") or (req is not None and req.text == "true"):
                problems.append(f"{obj}.{fld}: Product2 lookups must be optional with SetNull")
        if t == "Lookup":
            req = el.find("m:required", NS)
            dc = el.find("m:deleteConstraint", NS)
            if req is not None and req.text == "true" and dc is not None and dc.text == "SetNull":
                problems.append(f"{obj}.{fld}: required lookup cannot use SetNull")

# ---------------------------------------------------------------- platform limits (added after the 3B org gate)
LIMITS = [("permissionsets/*.xml", "description", 255), ("objects/*/fields/*.xml", "description", 1000),
          ("objects/*/fields/*.xml", "inlineHelpText", 510), ("objects/*/fields/*.xml", "label", 40),
          ("objects/*/*.object-meta.xml", "description", 1000), ("objects/*/validationRules/*.xml", "errorMessage", 255),
          ("objects/*/validationRules/*.xml", "description", 1000), ("tabs/*.xml", "description", 1000)]
for pattern, tag, limit in LIMITS:
    for fp in glob.glob(f"{ROOT}/{pattern}"):
        el = ET.parse(fp).getroot().find(f"m:{tag}", NS)
        if el is not None and el.text and len(el.text) > limit:
            problems.append(f"{os.path.relpath(fp, ROOT)}: {tag} is {len(el.text)} characters (max {limit})")
for fp in glob.glob(f"{ROOT}/objects/*/fields/*.xml"):
    for v in ET.parse(fp).getroot().iterfind(".//m:value/m:fullName", NS):
        if len(v.text) > 255:
            problems.append(f"{os.path.relpath(fp, ROOT)}: picklist value longer than 255 characters")
NOT_ON_LAYOUTS = {"CreatedDate", "LastModifiedDate", "SystemModstamp", "Id", "IsDeleted"}
for fp in glob.glob(f"{ROOT}/layouts/*.layout-meta.xml"):
    for f in ET.parse(fp).getroot().iterfind(".//m:layoutItems/m:field", NS):
        if f.text in NOT_ON_LAYOUTS:
            problems.append(f"{os.path.basename(fp)}: {f.text} cannot be placed on a layout")

print(f"checked {len(sources)} code files, {sum(len(v) for v in fields.values())} fields on {len(objects)} objects")
print("\n".join(problems) if problems else "no cross-reference problems")
sys.exit(1 if problems else 0)

