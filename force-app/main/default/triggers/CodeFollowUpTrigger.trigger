trigger CodeFollowUpTrigger on Code_Follow_Up__c(after update) {
    CodeFollowUpService.handleStatusChanges(Trigger.new, Trigger.oldMap);
}
