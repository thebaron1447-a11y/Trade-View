// Deletes all import batches (with their staging rows and attached files), everything a load booked from them (trades,
// AUM balances and their allocations), all code follow-ups, all AI request logs and every mapping profile Claude
// proposed, so the sample files can be pushed, loaded and sent to Claude again.
// Reference data (firms, advisors, codes, aliases, seeded profiles, matching rules) is kept.
// Changes made by approving roster rows or by hand (new advisors, codes, assignments, taught aliases) are NOT undone.
// Run: sf apex run --file scripts/apex/reset-imports.apex --target-org tradeDemo
delete [SELECT Id FROM Mapping_Profile__c WHERE Proposed_From_Batch__c != NULL OR Name LIKE '%proposed by Claude%' LIMIT 200];
Map<Id, Import_Batch__c> batches = new Map<Id, Import_Batch__c>([SELECT Id FROM Import_Batch__c LIMIT 2000]);
Set<Id> documentIds = new Set<Id>();
if (!batches.isEmpty()) {
    for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :batches.keySet()]) {
        documentIds.add(link.ContentDocumentId);
    }
}
// Bookings first: they point back to the rows they came from.
delete [SELECT Id FROM Trade_Allocation__c LIMIT 10000];
delete [SELECT Id FROM Trade__c LIMIT 10000];
delete [SELECT Id FROM AUM_Allocation__c LIMIT 10000];
delete [SELECT Id FROM AUM_Balance__c LIMIT 10000];
delete batches.values();
delete [SELECT Id FROM Code_Follow_Up__c LIMIT 5000];
delete [SELECT Id FROM AI_Request_Log__c LIMIT 5000];
delete [SELECT Id FROM ContentDocument WHERE Id IN :documentIds];
System.debug(LoggingLevel.INFO, 'Deleted ' + batches.size() + ' batches and ' + documentIds.size() + ' files.');
