trigger CodeFollowUpTrigger on Code_Follow_Up__c(before update, after update) {
    if (Trigger.isBefore) {
        SystemFieldGuard.check(Trigger.new, Trigger.oldMap);
        CodeFollowUpService.beforeSave(Trigger.new, Trigger.oldMap);
    } else {
        CodeFollowUpService.handleStatusChanges(Trigger.new, Trigger.oldMap);
    }
}
