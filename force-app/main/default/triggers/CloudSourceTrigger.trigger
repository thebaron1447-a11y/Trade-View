trigger CloudSourceTrigger on Cloud_Source__c(before insert, before update) {
    // A new or changed pull schedule sets the source's Next Pull At.
    CloudPullService.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
