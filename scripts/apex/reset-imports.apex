// Deletes all import batches (with their staging rows and attached files) and all code follow-ups,
// so the sample files can be pushed again. Reference data (firms, advisors, codes, aliases, profiles) is kept.
// Changes you made by hand to codes or assignments while testing are NOT undone.
// Run: sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
Map<Id, Import_Batch__c> batches = new Map<Id, Import_Batch__c>([SELECT Id FROM Import_Batch__c LIMIT 2000]);
Set<Id> documentIds = new Set<Id>();
if (!batches.isEmpty()) {
    for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :batches.keySet()]) {
        documentIds.add(link.ContentDocumentId);
    }
}
delete batches.values();
delete [SELECT Id FROM Code_Follow_Up__c LIMIT 5000];
delete [SELECT Id FROM ContentDocument WHERE Id IN :documentIds];
System.debug(LoggingLevel.INFO, 'Deleted ' + batches.size() + ' batches and ' + documentIds.size() + ' files.');
