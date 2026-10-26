"""Checks every LWC Apex import exists as an @AuraEnabled method and every call passes exactly its parameter names,
and every @salesforce/schema import names an object and field that exist in the package (or a standard field)."""
import re, glob, os, sys
ROOT = sys.argv[1] if len(sys.argv) > 1 else "/home/claude/build/force-app/main/default"
problems = []
sigs = {}
checked_imports = []
calls_checked = 0
for cls in glob.glob(f"{ROOT}/classes/*.cls"):
    src = open(cls).read()
    name = os.path.basename(cls)[:-4]
    for m in re.finditer(r"@AuraEnabled[^\n]*\n\s*public static [\w<>.,\s]+?\s(\w+)\(([^)]*)\)", src):
        params = [p.strip().split()[-1] for p in m.group(2).split(",") if p.strip()]
        sigs[f"{name}.{m.group(1)}"] = params
for js in glob.glob(f"{ROOT}/lwc/*/*.js"):
    src = open(js).read()
    imports = re.findall(r"import (\w+) from [\"']@salesforce/apex/([\w.]+)[\"'];", src)
    checked_imports.extend(imports)
    for local, target in imports:
        if target not in sigs:
            problems.append(f"{js}: {target} is not an @AuraEnabled method")
            continue
        for call in re.finditer(local + r"\(\{([^}]*)\}\)", src, re.S):
            calls_checked += 1
            # "name: value" pairs and shorthand properties ({ firmId })
            keys = [k.split(":")[0].strip() for k in call.group(1).split(",") if k.strip()]
            if sorted(keys) != sorted(sigs[target]):
                problems.append(f"{js}: {local}({{{', '.join(keys)}}}) does not match {target}({', '.join(sigs[target])})")
fields = set()
for f in glob.glob(f"{ROOT}/objects/*/fields/*.field-meta.xml"):
    parts = f.split(os.sep)
    fields.add(parts[-3] + "." + parts[-1].replace(".field-meta.xml", ""))
objects = {os.path.basename(d) for d in glob.glob(f"{ROOT}/objects/*")}
schema_checked = 0
for js in glob.glob(f"{ROOT}/lwc/*/*.js"):
    for target in re.findall(r"from [\"']@salesforce/schema/([\w.]+)[\"']", open(js).read()):
        schema_checked += 1
        obj = target.split(".")[0]
        if obj.endswith("__c") and obj not in objects:
            problems.append(f"{js}: schema object {obj} is not in the package")
        elif "." in target and target.split(".")[1].endswith("__c") and target not in fields:
            problems.append(f"{js}: schema field {target} is not in the package")
print("\n".join(problems) if problems else f"lwc xref: {len(checked_imports)} Apex imports and {calls_checked} calls match their @AuraEnabled methods; {schema_checked} schema imports exist")
sys.exit(1 if problems else 0)
