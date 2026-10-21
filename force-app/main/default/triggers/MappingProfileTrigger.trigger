trigger MappingProfileTrigger on Mapping_Profile__c(after insert, after update) {
    MappingActivationService.reprocessWaitingBatches(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
