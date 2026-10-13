// Creates Active mapping profiles for the BARDER, NORTHGATE and LUMIERE sample layouts.
// KESTREL is deliberately left without a profile so its file stops at Mapping Review.
// Safe to re-run: a profile is skipped if an Active profile with the same fingerprint already exists.
// Run: sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo

Mapping_Profile__c build(String name, String firmCode, Id firmId, List<String> headers, Map<String, String> columnMap,
                         String dateFormat, String decimalSeparator, String convention, Boolean singleFirm) {
    if (singleFirm && firmId == null) {
        throw new System.IllegalArgumentException('Firm Account not found for ' + firmCode + '. Load the phase 1 seed data first.');
    }
    return new Mapping_Profile__c(
        Name = name, Source_Firm__c = firmCode, Firm__c = firmId, Single_Firm_Feed__c = singleFirm,
        Header_Fingerprint__c = MappingService.fingerprint(headers), Column_Map__c = JSON.serializePretty(columnMap),
        Date_Format__c = dateFormat, Decimal_Separator__c = decimalSeparator, Direction_Convention__c = convention,
        Status__c = 'Active'
    );
}

Map<String, Id> firmIds = new Map<String, Id>();
for (Account a : [SELECT Id, Name FROM Account WHERE ParentId = null AND Name IN :new List<String>{ 'Barder & Company', 'Northgate Wealth Partners Inc.', 'Lumière Valeurs Mobilières Ltée' }]) {
    firmIds.put(a.Name, a.Id);
}

List<Mapping_Profile__c> profiles = new List<Mapping_Profile__c>();
profiles.add(build(
    'Barder - trade export', 'BARDER', firmIds.get('Barder & Company'),
    new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Advisor', 'Dealer Name', 'Fund Description', 'Gross Amt' },
    new Map<String, String>{ 'Trade Dt' => 'tradeDate', 'Dealer Rep #' => 'repCode', 'Advisor' => 'advisorName', 'Dealer Name' => 'firmName', 'Fund Description' => 'fundName', 'Gross Amt' => 'amount' },
    'MM/DD/YYYY', 'Period', 'Signed Amount', true
));
profiles.add(build(
    'Northgate - IA transactions', 'NORTHGATE', firmIds.get('Northgate Wealth Partners Inc.'),
    new List<String>{ 'IA Code', 'Rep Name', 'Firm', 'Branch', 'Product', 'Txn Type', 'Trade Date', 'Amount' },
    new Map<String, String>{ 'IA Code' => 'repCode', 'Rep Name' => 'advisorName', 'Firm' => 'firmName', 'Branch' => 'IGNORE', 'Product' => 'fundName', 'Txn Type' => 'transactionType', 'Trade Date' => 'tradeDate', 'Amount' => 'amount' },
    'DD/MM/YYYY', 'Period', 'Type Column', true
));
profiles.add(build(
    'Lumière - relevé des transactions', 'LUMIERE', firmIds.get('Lumière Valeurs Mobilières Ltée'),
    new List<String>{ 'Date de transaction', 'Code représentant', 'Nom du conseiller', 'Courtier', 'Fonds', 'Type', 'Montant' },
    new Map<String, String>{ 'Date de transaction' => 'tradeDate', 'Code représentant' => 'repCode', 'Nom du conseiller' => 'advisorName', 'Courtier' => 'firmName', 'Fonds' => 'fundName', 'Type' => 'transactionType', 'Montant' => 'amount' },
    'YYYY-MM-DD', 'Comma', 'Type Column', true
));

Set<String> existing = new Set<String>();
for (Mapping_Profile__c p : [SELECT Header_Fingerprint__c FROM Mapping_Profile__c WHERE Status__c = 'Active']) {
    existing.add(p.Header_Fingerprint__c);
}
List<Mapping_Profile__c> toInsert = new List<Mapping_Profile__c>();
for (Mapping_Profile__c p : profiles) {
    if (!existing.contains(p.Header_Fingerprint__c)) {
        toInsert.add(p);
    }
}
insert toInsert;
System.debug(LoggingLevel.INFO, 'Mapping profiles created: ' + toInsert.size() + ' of ' + profiles.size());
