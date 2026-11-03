/**
 * The staging row trigger's work, in order (audit F-28): the system field guard first, so it judges only what the
 * caller changed, and the lock on loaded rows; then the reviewer's decision (which sets stamps and match fields
 * itself); then the work a decision starts once the rows are saved.
 */
public with sharing class StagingRowTriggerHandler {
    public static void beforeUpdate(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        SystemFieldGuard.check(rows, previous);
        TradeLoader.protectLoaded(rows, previous);
        ReviewDecisionService.beforeUpdate(rows, previous);
    }

    public static void afterUpdate(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        ReviewDecisionService.afterUpdate(rows, previous);
    }
}
