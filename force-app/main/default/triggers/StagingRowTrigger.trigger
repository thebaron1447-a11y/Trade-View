trigger StagingRowTrigger on Import_Staging_Row__c(before update, after update) {
    if (Trigger.isBefore) {
        ReviewDecisionService.beforeUpdate(Trigger.new, Trigger.oldMap);
    } else {
        ReviewDecisionService.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
