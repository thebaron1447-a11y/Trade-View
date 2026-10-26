"""Writes scripts/apex/reset-reference-data.apex from the seed data files, so a full demo reset puts the reference data
(rep codes, assignments, aliases, advisors) back exactly as seeded. Firms, branches and funds keep their Ids, so
mapping profiles and everything else that points at them stay valid."""
import json, os

BUILD = "/home/claude/build"
DATA = f"{BUILD}/data"


def load(name):
    return json.load(open(f"{DATA}/{name}", encoding="utf-8"))["records"]


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "\\'") + "'"


def ref(v):
    return v[1:] if isinstance(v, str) and v.startswith("@") else v


firms = load("Account-firms.json")
branches = load("Account-branches.json")
account_name = {r["attributes"]["referenceId"]: r["Name"] for r in firms + branches}
contacts = load("Contact.json")
contact_key = {r["attributes"]["referenceId"]: f"{r['FirstName']}|{r['LastName']}|{account_name[ref(r['AccountId'])]}" for r in contacts}
products = load("Product2.json")
product_name = {r["attributes"]["referenceId"]: r["Name"] for r in products}
codes = load("Rep_Code__c.json")
code_key = {r["attributes"]["referenceId"]: f"{account_name[ref(r['Firm__c'])]}|{r['Name']}" for r in codes}
assignments = load("Rep_Code_Assignment__c.json")
firm_aliases = load("Firm_Alias__c.json")
fund_aliases = load("Fund_Alias__c.json")

L = []
L.append("""// Puts the demo's reference data back exactly as seeded, so every planted problem shows up again:
// deletes all rep codes, assignments, firm and fund aliases (including spellings taught by reviewers), matching rules,
// trades, and any advisor at the seeded firms who is not in the seed (for example Hannah Pierce or Priya Nair,
// created by approving roster rows), then recreates the seeded codes, assignments and aliases.
// Firms, branches, seeded advisors and funds keep their Ids. Run reset-imports.apex first (or use reset-demo-full.ps1).
// Generated from data/*.json by tools: gen_reset_full.py. Do not edit by hand.
// Run: sf apex run --file scripts/apex/reset-reference-data.apex --target-org tradeDemo
""")
L.append("List<String> accountNames = new List<String>{ " + ", ".join(lit(n) for n in account_name.values()) + " };")
L.append("""Map<String, Id> accounts = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE Name IN :accountNames]) {
    accounts.put(a.Name, a.Id);
}
List<String> missingAccounts = new List<String>();
for (String n : accountNames) {
    if (!accounts.containsKey(n)) {
        missingAccounts.add(n);
    }
}
if (!missingAccounts.isEmpty()) {
    throw new System.IllegalArgumentException('Seed accounts not found: ' + String.join(missingAccounts, ', ') + '. Load the seed data first.');
}

delete [SELECT Id FROM Trade_Allocation__c LIMIT 10000];
delete [SELECT Id FROM Trade__c LIMIT 10000];
delete [SELECT Id FROM Matching_Rule__c LIMIT 10000];
delete [SELECT Id FROM Rep_Code_Assignment__c LIMIT 10000];
delete [SELECT Id FROM Rep_Code__c LIMIT 10000];
delete [SELECT Id FROM Firm_Alias__c LIMIT 10000];
delete [SELECT Id FROM Fund_Alias__c LIMIT 10000];
""")
L.append("Map<String, Contact> seedContacts = new Map<String, Contact>{")
L.append(",\n".join(
    f"    {lit(contact_key[r['attributes']['referenceId']])} => new Contact(FirstName = {lit(r['FirstName'])}, LastName = {lit(r['LastName'])}, "
    f"AccountId = accounts.get({lit(account_name[ref(r['AccountId'])])}), Title = {lit(r.get('Title'))})" for r in contacts))
L.append("};")
L.append("""Map<String, Id> contactIds = new Map<String, Id>();
List<Contact> extraContacts = new List<Contact>();
for (Contact c : [SELECT Id, FirstName, LastName, Account.Name FROM Contact WHERE AccountId IN :accounts.values()]) {
    String k = c.FirstName + '|' + c.LastName + '|' + c.Account.Name;
    if (seedContacts.containsKey(k) && !contactIds.containsKey(k)) {
        contactIds.put(k, c.Id);
    } else {
        extraContacts.add(c);
    }
}
delete extraContacts;
List<Contact> missingContacts = new List<Contact>();
for (String k : seedContacts.keySet()) {
    if (!contactIds.containsKey(k)) {
        missingContacts.add(seedContacts.get(k));
    }
}
insert missingContacts;
for (String k : seedContacts.keySet()) {
    if (seedContacts.get(k).Id != null) {
        contactIds.put(k, seedContacts.get(k).Id);
    }
}
""")
L.append("Map<String, Product2> seedFunds = new Map<String, Product2>{")
L.append(",\n".join(
    f"    {lit(r['Name'])} => new Product2(Name = {lit(r['Name'])}, ProductCode = {lit(r.get('ProductCode'))}, "
    f"Description = {lit(r.get('Description'))}, IsActive = {lit(r.get('IsActive', True))})" for r in products))
L.append("};")
L.append("""Map<String, Id> funds = new Map<String, Id>();
for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :seedFunds.keySet()]) {
    funds.put(p.Name, p.Id);
}
List<Product2> missingFunds = new List<Product2>();
for (String n : seedFunds.keySet()) {
    if (!funds.containsKey(n)) {
        missingFunds.add(seedFunds.get(n));
    }
}
insert missingFunds;
for (Product2 p : missingFunds) {
    funds.put(p.Name, p.Id);
}
""")
L.append("Map<String, Rep_Code__c> codes = new Map<String, Rep_Code__c>{")
L.append(",\n".join(
    f"    {lit(code_key[r['attributes']['referenceId']])} => new Rep_Code__c(Name = {lit(r['Name'])}, Firm__c = accounts.get({lit(account_name[ref(r['Firm__c'])])}))"
    for r in codes))
L.append("};\ninsert codes.values();\n")
L.append("List<Rep_Code_Assignment__c> assignments = new List<Rep_Code_Assignment__c>{")
rows = []
for r in assignments:
    parts = [f"Rep_Code__c = codes.get({lit(code_key[ref(r['Rep_Code__c'])])}).Id",
             f"Advisor__c = contactIds.get({lit(contact_key[ref(r['Advisor__c'])])})",
             f"Allocation_Percent__c = {lit(r['Allocation_Percent__c'])}",
             f"Effective_Start_Date__c = Date.valueOf({lit(r['Effective_Start_Date__c'])})"]
    if r.get("Effective_End_Date__c"):
        parts.append(f"Effective_End_Date__c = Date.valueOf({lit(r['Effective_End_Date__c'])})")
    if r.get("Last_Confirmed_Trade_Date__c"):
        parts.append(f"Last_Confirmed_Trade_Date__c = Date.valueOf({lit(r['Last_Confirmed_Trade_Date__c'])})")
    if r.get("End_Date_Source__c"):
        parts.append(f"End_Date_Source__c = {lit(r['End_Date_Source__c'])}")
    rows.append("    new Rep_Code_Assignment__c(" + ", ".join(parts) + ")")
L.append(",\n".join(rows))
L.append("};\ninsert assignments;\n")
L.append("List<SObject> aliases = new List<SObject>{")
alias_rows = [f"    new Firm_Alias__c(Name = {lit(r['Name'])}, Normalized_Key__c = {lit(r['Normalized_Key__c'])}, Firm__c = accounts.get({lit(account_name[ref(r['Firm__c'])])}))"
              for r in firm_aliases]
alias_rows += [f"    new Fund_Alias__c(Name = {lit(r['Name'])}, Normalized_Key__c = {lit(r['Normalized_Key__c'])}, Fund__c = funds.get({lit(product_name[ref(r['Fund__c'])])}))"
               for r in fund_aliases]
L.append(",\n".join(alias_rows))
L.append("};\ninsert aliases;\n")
L.append(f"""System.debug(LoggingLevel.INFO, 'Reference data reset: ' + codes.size() + ' codes, ' + assignments.size() + ' assignments, ' +
    aliases.size() + ' aliases; removed ' + extraContacts.size() + ' advisors not in the seed; restored ' + missingContacts.size() +
    ' advisors and ' + missingFunds.size() + ' funds.');
""")
out = f"{BUILD}/scripts/apex/reset-reference-data.apex"
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(L))
print(f"written {out}: {len(codes)} codes, {len(assignments)} assignments, {len(firm_aliases) + len(fund_aliases)} aliases, {len(contacts)} advisors")
