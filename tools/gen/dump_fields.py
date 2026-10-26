"""Writes doc/fields_live.json: field definitions read from the built metadata, in the agreed block format."""
import glob, json, xml.etree.ElementTree as ET
NS = {"m": "http://soap.sforce.com/2006/04/metadata"}
ROOT = "/home/claude/build/force-app/main/default/objects"
LABEL = {"Account": "Account", "Contact": "Contact", "Product2": "Product2", "Rep_Code__c": "Rep Code", "User": "User",
         "Code_Follow_Up__c": "Code Follow-Up", "Import_Staging_Row__c": "Import Staging Row",
         "AI_Request_Log__c": "AI Request Log", "Import_Batch__c": "Import Batch"}
WANT = {
    "Mapping_Profile__c": ["Feed_Type__c", "AUM_Indicator_Values__c"],
    "Import_Staging_Row__c": ["Row_Type__c", "Source_Branch_Name__c", "Match_Status__c", "Matched_Firm__c", "Matched_Rep_Code__c",
                              "Matched_Fund__c", "Credited_Advisor__c", "Code_Follow_Up__c", "Match_Method__c", "Match_Flags__c",
                              "Match_Notes__c", "Match_Candidates__c"],
    "Import_Batch__c": ["Matched_Row_Count__c", "Review_Row_Count__c", "Held_Row_Count__c"],
    "Code_Follow_Up__c": ["Rep_Code_Value__c", "Rep_Code__c", "Firm__c", "Reason__c", "Status__c", "Follow_Up_Key__c",
                          "Held_Row_Count__c", "Held_Amount__c", "Last_Seen_Date__c", "Suggested_Resolution__c", "Resolution_Notes__c"],
}
# Phase 3B
WANT_3B = {
    "Import_Staging_Row__c": ["AI_Status__c", "AI_Confidence__c", "AI_Suggestion__c", "AI_Suggested_Firm__c", "AI_Suggested_Fund__c",
                              "AI_Suggested_Advisor__c", "AI_Request__c", "Reviewer_Decision__c", "Firm_Override__c", "Fund_Override__c",
                              "Remember_Choice__c", "Decided_By__c", "Decided_At__c"],
    "Code_Follow_Up__c": ["AI_Status__c", "AI_Confidence__c", "AI_Suggested_Advisor__c", "AI_Request__c"],
    "Import_Batch__c": ["Header_Fingerprint__c"],
    "Mapping_Profile__c": ["AI_Rationale__c", "Proposed_From_Batch__c"],
    "AI_Request_Log__c": ["Purpose__c", "Status__c", "Model_Name__c", "Prompt__c", "Response__c", "Error_Message__c", "Item_Count__c",
                          "Duration_Ms__c", "Import_Batch__c"],
    "Matching_Rule__c": ["Firm__c", "Rule__c", "Status__c", "Approved_By__c", "Approved_At__c"],
    "Trade_AI_Setting__mdt": ["Enabled__c", "Model_Name__c", "Max_Items_Per_Request__c", "Require_Two_Person_Rule_Approval__c"],
}

# Phase 4a: Standard tier (Anthropic API provider)
WANT_4A = {
    "AI_Request_Log__c": ["Provider__c", "Model_Name__c"],
    "Trade_AI_Setting__mdt": ["Provider__c", "Model_Name__c", "Anthropic_Model__c"],
}

# Phase 4b: review app
WANT_4B = {
    "Import_Staging_Row__c": ["Assigned_To__c"],
    "Code_Follow_Up__c": ["Assigned_To__c"],
}


# Phase 4b.2: headlines, hold, per-field answers, firm follow-up, token logging
WANT_4B2 = {
    "Import_Staging_Row__c": ["AI_Headline__c", "AI_Recommended_Action__c", "AI_Homework__c", "AI_Field_Suggestions__c",
                              "On_Hold__c", "On_Hold_Reason__c", "On_Hold_By__c", "On_Hold_Since__c", "Asked_Firm_At__c"],
    "Code_Follow_Up__c": ["AI_Homework__c", "AI_Field_Suggestions__c", "Asked_Firm_At__c"],
    "Account": ["Operations_Contact__c"],
    "AI_Request_Log__c": ["Input_Tokens__c", "Output_Tokens__c", "Cached_Input_Tokens__c", "Purpose__c"],
}


WANT_4B3 = {"Import_Staging_Row__c": ["Issue_Key__c"]}


def g(r, t):
    e = r.find("m:" + t, NS)
    return e.text if e is not None else None


def type_text(r):
    t = g(r, "type")
    req = ", required" if g(r, "required") == "true" else ""
    if t == "Picklist":
        vals, default = [], None
        for v in r.iterfind(".//m:value", NS):
            vals.append(v.find("m:fullName", NS).text)
            if g(v, "default") == "true":
                default = vals[-1]
        return f"Picklist (values: {', '.join(vals)})" + req + (f", default {default}" if default else "")
    if t == "Lookup":
        return f"Lookup({LABEL[g(r, 'referenceTo')]}), optional, clear value if deleted"
    if t == "Text":
        return f"Text({g(r, 'length')})" + req + (", Unique, External ID" if g(r, "unique") == "true" else
                                                   ", External ID (not unique)" if g(r, "externalId") == "true" else "")
    if t == "DateTime":
        return "Date/Time" + req
    if t == "Checkbox":
        return "Checkbox (default " + ("checked" if g(r, "defaultValue") == "true" else "unchecked") + ")"
    if t == "LongTextArea":
        return f"Long Text Area({g(r, 'length')})"
    if t in ("Number", "Currency"):
        return f"{t}({g(r, 'precision')},{g(r, 'scale')})" + req
    if t == "Number" and g(r, "precision") and not g(r, "fieldManageability"):
        pass
    if t == "Summary":
        f = r.find("m:summaryFilterItems", NS)
        return (f"Roll-Up Summary (COUNT of Import Staging Row, filter: Match Status equals {g(f, 'value')})")
    return t + req


out = {}
for obj, names in list(WANT.items()) + [(o + "@3B", n) for o, n in WANT_3B.items()] + [(o + "@4A", n) for o, n in WANT_4A.items()] + [(o + "@4B", n) for o, n in WANT_4B.items()] + [(o + "@4B2", n) for o, n in WANT_4B2.items()] + [(o + "@4B3", n) for o, n in WANT_4B3.items()]:
    out[obj] = []
    for n in names:
        obj_dir = obj.split("@")[0]
        r = ET.parse(f"{ROOT}/{obj_dir}/fields/{n}.field-meta.xml").getroot()
        out[obj].append(dict(name=g(r, "label"), api=n, type=type_text(r), desc=g(r, "description"), help=g(r, "inlineHelpText")))
json.dump(out, open("/home/claude/doc/fields_live.json", "w"), indent=1, ensure_ascii=False)
print({k: len(v) for k, v in out.items()})
