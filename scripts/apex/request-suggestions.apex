// Asks Claude again about rows in Needs Review and open follow-ups whose suggestion Failed or was Invalid,
// plus anything never asked (for example when the job chain stopped early), then queues the suggestion job.
// Run: sf apex run --file scripts/apex/request-suggestions.apex --target-org tradeDemo
List<Import_Staging_Row__c> rows = [
    SELECT Id FROM Import_Staging_Row__c
    WHERE Match_Status__c = 'Needs Review' AND AI_Status__c IN ('Failed', 'Invalid') AND Reviewer_Decision__c = NULL
    LIMIT 500
];
List<Import_Staging_Row__c> rowResets = new List<Import_Staging_Row__c>();
for (Import_Staging_Row__c r : rows) {
    rowResets.add(new Import_Staging_Row__c(Id = r.Id, AI_Status__c = null));
}
update rowResets;
List<Code_Follow_Up__c> followUps = [
    SELECT Id FROM Code_Follow_Up__c
    WHERE Status__c IN ('Open', 'In Progress') AND AI_Status__c IN ('Failed', 'Invalid')
    LIMIT 500
];
List<Code_Follow_Up__c> followUpResets = new List<Code_Follow_Up__c>();
for (Code_Follow_Up__c f : followUps) {
    followUpResets.add(new Code_Follow_Up__c(Id = f.Id, AI_Status__c = null));
}
update followUpResets;
Id jobId = System.enqueueJob(new ClaudeSuggestionJob(null));
System.debug(LoggingLevel.INFO, 'Reset ' + rowResets.size() + ' rows and ' + followUpResets.size() + ' follow-ups; queued job ' + jobId);
