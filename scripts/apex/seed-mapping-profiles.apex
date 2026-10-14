// Creates or updates the Active mapping profiles for the sample feeds, matched by profile name.
// Phase 3: Barder's export gains a Record Type column (AUM rows), Northgate maps Branch, AUM indicators
// are set, and a Barder advisor code roster profile is added. KESTREL is left without a profile on purpose.
// Safe to re-run. Run: sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo

Mapping_Profile__c build(String name, String firmCode, Id firmId, String feedType, String aumIndicators, List<String> headers,
                         Map<String, String> columnMap, String dateFormat, String decimalSeparator, String convention, Boolean singleFirm) {
    if (singleFirm && firmId == null) {
        throw new System.IllegalArgumentException('Firm Account not found for ' + firmCode + '. Load the phase 1 seed data first.');
    }
    return new Mapping_Profile__c(
        Name = name, Source_Firm__c = firmCode, Firm__c = firmId, Single_Firm_Feed__c = singleFirm, Feed_Type__c = feedType,
        AUM_Indicator_Values__c = aumIndicators, Header_Fingerprint__c = MappingService.fingerprint(headers),
        Column_Map__c = JSON.serializePretty(columnMap), Date_Format__c = dateFormat, Decimal_Separator__c = decimalSeparator,
        Direction_Convention__c = convention, Status__c = 'Active'
    );
}

Map<String, Id> firmIds = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE ParentId = null AND Name IN :new List<String>{ 'Barder & Company', 'Northgate Wealth Partners Inc.', 'Lumière Valeurs Mobilières Ltée' }]) {
    firmIds.put(a.Name, a.Id);
}

List<Mapping_Profile__c> profiles = new List<Mapping_Profile__c>();
profiles.add(build(
    'Barder - trade export', 'BARDER', firmIds.get('Barder & Company'), 'Trade Activity', 'AUM',
    new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Advisor', 'Dealer Name', 'Fund Description', 'Record Type', 'Gross Amt' },
    new Map<String, String>{ 'Trade Dt' => 'tradeDate', 'Dealer Rep #' => 'repCode', 'Advisor' => 'advisorName', 'Dealer Name' => 'firmName', 'Fund Description' => 'fundName', 'Record Type' => 'rowType', 'Gross Amt' => 'amount' },
    'MM/DD/YYYY', 'Period', 'Signed Amount', true
));
profiles.add(build(
    'Northgate - IA transactions', 'NORTHGATE', firmIds.get('Northgate Wealth Partners Inc.'), 'Trade Activity', 'POSITION',
    new List<String>{ 'IA Code', 'Rep Name', 'Firm', 'Branch', 'Product', 'Txn Type', 'Trade Date', 'Amount' },
    new Map<String, String>{ 'IA Code' => 'repCode', 'Rep Name' => 'advisorName', 'Firm' => 'firmName', 'Branch' => 'branchName', 'Product' => 'fundName', 'Txn Type' => 'transactionType', 'Trade Date' => 'tradeDate', 'Amount' => 'amount' },
    'DD/MM/YYYY', 'Period', 'Type Column', true
));
profiles.add(build(
    'Lumière - relevé des transactions', 'LUMIERE', firmIds.get('Lumière Valeurs Mobilières Ltée'), 'Trade Activity', 'SOLDE',
    new List<String>{ 'Date de transaction', 'Code représentant', 'Nom du conseiller', 'Courtier', 'Fonds', 'Type', 'Montant' },
    new Map<String, String>{ 'Date de transaction' => 'tradeDate', 'Code représentant' => 'repCode', 'Nom du conseiller' => 'advisorName', 'Courtier' => 'firmName', 'Fonds' => 'fundName', 'Type' => 'transactionType', 'Montant' => 'amount' },
    'YYYY-MM-DD', 'Comma', 'Type Column', true
));
profiles.add(build(
    'Barder - advisor code roster', 'BARDER', firmIds.get('Barder & Company'), 'Advisor Code Roster', null,
    new List<String>{ 'Rep Code', 'Advisor Name', 'Branch', 'Effective Date' },
    new Map<String, String>{ 'Rep Code' => 'repCode', 'Advisor Name' => 'advisorName', 'Branch' => 'branchName', 'Effective Date' => 'tradeDate' },
    'MM/DD/YYYY', 'Period', 'Type Column', true
));

Map<String, Id> existing = new Map<String, Id>();
for (Mapping_Profile__c p : [SELECT Id, Name FROM Mapping_Profile__c WHERE Name IN :new List<String>{ 'Barder - trade export', 'Northgate - IA transactions', 'Lumière - relevé des transactions', 'Barder - advisor code roster' }]) {
    existing.put(p.Name, p.Id);
}
Integer created = 0;
Integer updated = 0;
for (Mapping_Profile__c p : profiles) {
    if (existing.containsKey(p.Name)) {
        p.Id = existing.get(p.Name);
        updated++;
    } else {
        created++;
    }
}
upsert profiles;
System.debug(LoggingLevel.INFO, 'Mapping profiles created: ' + created + ', updated: ' + updated);
