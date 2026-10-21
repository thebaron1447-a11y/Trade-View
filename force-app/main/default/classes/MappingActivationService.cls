/**
 * When a mapping profile becomes Active, batches waiting in Mapping Review for the same file layout are sent
 * back to Received and processed again, so approving Claude's proposal (or any new profile) finishes the job
 * without re-sending the file.
 */
public with sharing class MappingActivationService {
    @TestVisible
    private static final Integer MAX_BATCHES = 20;

    /**
     * After insert and after update handler. previous is null on insert.
     * One ImportBatchProcessor job per waiting file, so each file gets full limits. The loop is bounded by
     * MAX_BATCHES and checks the queueable limit on every pass, hence the suppression.
     */
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    public static void reprocessWaitingBatches(List<Mapping_Profile__c> profiles, Map<Id, Mapping_Profile__c> previous) {
        Set<String> fingerprints = new Set<String>();
        for (Mapping_Profile__c p : profiles) {
            Mapping_Profile__c before = previous == null ? null : previous.get(p.Id);
            Boolean activated = p.Status__c == 'Active' && (before == null || before.Status__c != 'Active');
            if (activated && String.isNotBlank(p.Header_Fingerprint__c)) {
                fingerprints.add(p.Header_Fingerprint__c);
            }
        }
        if (fingerprints.isEmpty()) {
            return;
        }
        List<Import_Batch__c> resets = new List<Import_Batch__c>();
        for (Import_Batch__c b : [
            SELECT Id
            FROM Import_Batch__c
            WHERE Status__c = :ImportBatchProcessor.STATUS_MAPPING_REVIEW AND Header_Fingerprint__c IN :fingerprints
            WITH USER_MODE
            ORDER BY CreatedDate
            LIMIT :MAX_BATCHES
        ]) {
            resets.add(new Import_Batch__c(Id = b.Id, Status__c = ImportBatchProcessor.STATUS_RECEIVED, Error_Message__c = null));
        }
        update as user resets;
        for (Import_Batch__c b : resets) {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new ImportBatchProcessor(b.Id));
            }
        }
    }
}
