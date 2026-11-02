trigger StagingRowTrigger on Import_Staging_Row__c(before update, after update) {
    if (Trigger.isBefore) {
        StagingRowTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    } else {
        StagingRowTriggerHandler.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
