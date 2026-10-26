// Puts the demo's reference data back exactly as seeded, so every planted problem shows up again:
// deletes all rep codes, assignments, firm and fund aliases (including spellings taught by reviewers), matching rules,
// trades, and any advisor at the seeded firms who is not in the seed (for example Hannah Pierce or Priya Nair,
// created by approving roster rows), then recreates the seeded codes, assignments and aliases.
// Firms, branches, seeded advisors and funds keep their Ids. Run reset-imports.apex first (or use reset-demo-full.ps1).
// Generated from data/*.json by tools: gen_reset_full.py. Do not edit by hand.
// Run: sf apex run --file scripts/apex/reset-reference-data.apex --target-org tradeDemo

List<String> accountNames = new List<String>{ 'Barder & Company', 'Northgate Wealth Partners Inc.', 'Lumière Valeurs Mobilières Ltée', 'Kestrel Capital Inc.', 'Kestrel Capital Ltd.', 'Barder & Company - Oakville', 'Barder & Company - Hamilton', 'Northgate Wealth Partners - Toronto', 'Lumière Valeurs Mobilières - Montréal', 'Kestrel Capital Inc. - Calgary', 'Kestrel Capital Ltd. - Vancouver' };
Map<String, Id> accounts = new Map<String, Id>();
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

Map<String, Contact> seedContacts = new Map<String, Contact>{
    'Julia|Morales|Barder & Company - Oakville' => new Contact(FirstName = 'Julia', LastName = 'Morales', AccountId = accounts.get('Barder & Company - Oakville'), Title = 'Investment Advisor'),
    'Marcus|Bell|Barder & Company - Hamilton' => new Contact(FirstName = 'Marcus', LastName = 'Bell', AccountId = accounts.get('Barder & Company - Hamilton'), Title = 'Investment Advisor'),
    'Tom|Reilly|Northgate Wealth Partners - Toronto' => new Contact(FirstName = 'Tom', LastName = 'Reilly', AccountId = accounts.get('Northgate Wealth Partners - Toronto'), Title = 'Investment Advisor'),
    'Aisha|Khan|Northgate Wealth Partners - Toronto' => new Contact(FirstName = 'Aisha', LastName = 'Khan', AccountId = accounts.get('Northgate Wealth Partners - Toronto'), Title = 'Investment Advisor'),
    'Daniel|Okafor|Northgate Wealth Partners - Toronto' => new Contact(FirstName = 'Daniel', LastName = 'Okafor', AccountId = accounts.get('Northgate Wealth Partners - Toronto'), Title = 'Investment Advisor'),
    'Sam|Whitford|Northgate Wealth Partners - Toronto' => new Contact(FirstName = 'Sam', LastName = 'Whitford', AccountId = accounts.get('Northgate Wealth Partners - Toronto'), Title = 'Investment Advisor'),
    'Élise|Gagnon|Lumière Valeurs Mobilières - Montréal' => new Contact(FirstName = 'Élise', LastName = 'Gagnon', AccountId = accounts.get('Lumière Valeurs Mobilières - Montréal'), Title = 'Investment Advisor'),
    'Marc-André|Roy|Lumière Valeurs Mobilières - Montréal' => new Contact(FirstName = 'Marc-André', LastName = 'Roy', AccountId = accounts.get('Lumière Valeurs Mobilières - Montréal'), Title = 'Investment Advisor'),
    'Ryan|Chen|Kestrel Capital Inc. - Calgary' => new Contact(FirstName = 'Ryan', LastName = 'Chen', AccountId = accounts.get('Kestrel Capital Inc. - Calgary'), Title = 'Investment Advisor'),
    'Megan|Chen|Kestrel Capital Ltd. - Vancouver' => new Contact(FirstName = 'Megan', LastName = 'Chen', AccountId = accounts.get('Kestrel Capital Ltd. - Vancouver'), Title = 'Investment Advisor')
};
Map<String, Id> contactIds = new Map<String, Id>();
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

Map<String, Product2> seedFunds = new Map<String, Product2>{
    'Wealth World Fund - Series A' => new Product2(Name = 'Wealth World Fund - Series A', ProductCode = 'WWF-A', Description = 'Mutual fund, Series A', IsActive = true),
    'Wealth World Fund - Series F' => new Product2(Name = 'Wealth World Fund - Series F', ProductCode = 'WWF-F', Description = 'Mutual fund, Series F', IsActive = true),
    'Wealth World ETF' => new Product2(Name = 'Wealth World ETF', ProductCode = 'WWE', Description = 'Exchange-traded fund', IsActive = true),
    'Canadian Dividend Fund - Series A' => new Product2(Name = 'Canadian Dividend Fund - Series A', ProductCode = 'CDF-A', Description = 'Mutual fund, Series A', IsActive = true),
    'Global Bond Fund - Series F' => new Product2(Name = 'Global Bond Fund - Series F', ProductCode = 'GBF-F', Description = 'Mutual fund, Series F', IsActive = true)
};
Map<String, Id> funds = new Map<String, Id>();
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

Map<String, Rep_Code__c> codes = new Map<String, Rep_Code__c>{
    'Northgate Wealth Partners Inc.|3102' => new Rep_Code__c(Name = '3102', Firm__c = accounts.get('Northgate Wealth Partners Inc.')),
    'Barder & Company|457' => new Rep_Code__c(Name = '457', Firm__c = accounts.get('Barder & Company')),
    'Barder & Company|2210' => new Rep_Code__c(Name = '2210', Firm__c = accounts.get('Barder & Company')),
    'Northgate Wealth Partners Inc.|5521' => new Rep_Code__c(Name = '5521', Firm__c = accounts.get('Northgate Wealth Partners Inc.')),
    'Lumière Valeurs Mobilières Ltée|7700' => new Rep_Code__c(Name = '7700', Firm__c = accounts.get('Lumière Valeurs Mobilières Ltée')),
    'Northgate Wealth Partners Inc.|8800' => new Rep_Code__c(Name = '8800', Firm__c = accounts.get('Northgate Wealth Partners Inc.')),
    'Kestrel Capital Inc.|1001' => new Rep_Code__c(Name = '1001', Firm__c = accounts.get('Kestrel Capital Inc.')),
    'Kestrel Capital Ltd.|1001' => new Rep_Code__c(Name = '1001', Firm__c = accounts.get('Kestrel Capital Ltd.'))
};
insert codes.values();

List<Rep_Code_Assignment__c> assignments = new List<Rep_Code_Assignment__c>{
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Northgate Wealth Partners Inc.|3102').Id, Advisor__c = contactIds.get('Julia|Morales|Barder & Company - Oakville'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2019-03-01'), Effective_End_Date__c = Date.valueOf('2024-05-28'), Last_Confirmed_Trade_Date__c = Date.valueOf('2024-05-28'), End_Date_Source__c = 'Inferred from Review'),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Barder & Company|457').Id, Advisor__c = contactIds.get('Julia|Morales|Barder & Company - Oakville'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2024-06-15'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-28')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Barder & Company|2210').Id, Advisor__c = contactIds.get('Marcus|Bell|Barder & Company - Hamilton'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2018-01-08'), Last_Confirmed_Trade_Date__c = Date.valueOf('2025-11-14')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Northgate Wealth Partners Inc.|5521').Id, Advisor__c = contactIds.get('Tom|Reilly|Northgate Wealth Partners - Toronto'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2020-09-01'), Last_Confirmed_Trade_Date__c = Date.valueOf('2025-02-03')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Lumière Valeurs Mobilières Ltée|7700').Id, Advisor__c = contactIds.get('Élise|Gagnon|Lumière Valeurs Mobilières - Montréal'), Allocation_Percent__c = 60, Effective_Start_Date__c = Date.valueOf('2021-01-04'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-30')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Lumière Valeurs Mobilières Ltée|7700').Id, Advisor__c = contactIds.get('Marc-André|Roy|Lumière Valeurs Mobilières - Montréal'), Allocation_Percent__c = 40, Effective_Start_Date__c = Date.valueOf('2021-01-04'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-30')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Northgate Wealth Partners Inc.|8800').Id, Advisor__c = contactIds.get('Aisha|Khan|Northgate Wealth Partners - Toronto'), Allocation_Percent__c = 50, Effective_Start_Date__c = Date.valueOf('2022-04-01'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-25')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Northgate Wealth Partners Inc.|8800').Id, Advisor__c = contactIds.get('Daniel|Okafor|Northgate Wealth Partners - Toronto'), Allocation_Percent__c = 30, Effective_Start_Date__c = Date.valueOf('2022-04-01'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-25')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Northgate Wealth Partners Inc.|8800').Id, Advisor__c = contactIds.get('Sam|Whitford|Northgate Wealth Partners - Toronto'), Allocation_Percent__c = 20, Effective_Start_Date__c = Date.valueOf('2022-04-01'), Effective_End_Date__c = Date.valueOf('2026-03-31'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-03-27'), End_Date_Source__c = 'Confirmed by Firm'),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Kestrel Capital Inc.|1001').Id, Advisor__c = contactIds.get('Ryan|Chen|Kestrel Capital Inc. - Calgary'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2023-02-01'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-09-15')),
    new Rep_Code_Assignment__c(Rep_Code__c = codes.get('Kestrel Capital Ltd.|1001').Id, Advisor__c = contactIds.get('Megan|Chen|Kestrel Capital Ltd. - Vancouver'), Allocation_Percent__c = 100, Effective_Start_Date__c = Date.valueOf('2021-06-01'), Last_Confirmed_Trade_Date__c = Date.valueOf('2026-08-30'))
};
insert assignments;

List<SObject> aliases = new List<SObject>{
    new Firm_Alias__c(Name = 'Barder & Company', Normalized_Key__c = 'barder', Firm__c = accounts.get('Barder & Company')),
    new Firm_Alias__c(Name = 'Northgate Wealth Partners Inc.', Normalized_Key__c = 'northgate wealth partners', Firm__c = accounts.get('Northgate Wealth Partners Inc.')),
    new Firm_Alias__c(Name = 'Northgate WP', Normalized_Key__c = 'northgate wp', Firm__c = accounts.get('Northgate Wealth Partners Inc.')),
    new Firm_Alias__c(Name = 'Lumière Valeurs Mobilières Ltée', Normalized_Key__c = 'lumière valeurs mobilières', Firm__c = accounts.get('Lumière Valeurs Mobilières Ltée')),
    new Firm_Alias__c(Name = 'Lumiere Valeurs Mobilieres', Normalized_Key__c = 'lumiere valeurs mobilieres', Firm__c = accounts.get('Lumière Valeurs Mobilières Ltée')),
    new Firm_Alias__c(Name = 'Kestrel Capital Inc.', Normalized_Key__c = 'kestrel capital', Firm__c = accounts.get('Kestrel Capital Inc.')),
    new Firm_Alias__c(Name = 'Kestrel Capital Ltd.', Normalized_Key__c = 'kestrel capital', Firm__c = accounts.get('Kestrel Capital Ltd.')),
    new Fund_Alias__c(Name = 'Wealth World Fund - Series A', Normalized_Key__c = 'wealth world fund series a', Fund__c = funds.get('Wealth World Fund - Series A')),
    new Fund_Alias__c(Name = 'Wealth World Fund A', Normalized_Key__c = 'wealth world fund a', Fund__c = funds.get('Wealth World Fund - Series A')),
    new Fund_Alias__c(Name = 'WEALTH WORLD FD SER A', Normalized_Key__c = 'wealth world fd ser a', Fund__c = funds.get('Wealth World Fund - Series A')),
    new Fund_Alias__c(Name = 'Wealth World Fund - Series F', Normalized_Key__c = 'wealth world fund series f', Fund__c = funds.get('Wealth World Fund - Series F')),
    new Fund_Alias__c(Name = 'Wealth World ETF', Normalized_Key__c = 'wealth world etf', Fund__c = funds.get('Wealth World ETF')),
    new Fund_Alias__c(Name = 'Canadian Dividend Fund - Series A', Normalized_Key__c = 'canadian dividend fund series a', Fund__c = funds.get('Canadian Dividend Fund - Series A')),
    new Fund_Alias__c(Name = 'Cdn Dividend Fund A', Normalized_Key__c = 'cdn dividend fund a', Fund__c = funds.get('Canadian Dividend Fund - Series A')),
    new Fund_Alias__c(Name = 'Global Bond Fund - Series F', Normalized_Key__c = 'global bond fund series f', Fund__c = funds.get('Global Bond Fund - Series F')),
    new Fund_Alias__c(Name = 'Wealth World Fund', Normalized_Key__c = 'wealth world fund', Fund__c = funds.get('Wealth World Fund - Series A')),
    new Fund_Alias__c(Name = 'Wealth World Fund', Normalized_Key__c = 'wealth world fund', Fund__c = funds.get('Wealth World Fund - Series F'))
};
insert aliases;

System.debug(LoggingLevel.INFO, 'Reference data reset: ' + codes.size() + ' codes, ' + assignments.size() + ' assignments, ' +
    aliases.size() + ' aliases; removed ' + extraContacts.size() + ' advisors not in the seed; restored ' + missingContacts.size() +
    ' advisors and ' + missingFunds.size() + ' funds.');
