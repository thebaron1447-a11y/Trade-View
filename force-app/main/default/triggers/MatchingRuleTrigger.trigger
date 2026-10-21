trigger MatchingRuleTrigger on Matching_Rule__c(before insert, before update) {
    MatchingRuleService.enforceApproval(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
