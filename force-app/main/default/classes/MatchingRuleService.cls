/**
 * Matching rules are instructions given to Claude, so changing them changes what the AI suggests. When the
 * Trade AI Setting requires it, a rule must be activated by someone other than its author (two-person rule),
 * and who activated it and when are recorded by the system.
 */
public with sharing class MatchingRuleService {
    public static final String ACTIVE = 'Active';

    /** Before insert and before update handler. previous is null on insert. */
    public static void enforceApproval(List<Matching_Rule__c> rules, Map<Id, Matching_Rule__c> previous) {
        Boolean twoPerson = AiSettings.get().requireTwoPersonRuleApproval;
        Id me = UserInfo.getUserId();
        for (Matching_Rule__c r : rules) {
            Matching_Rule__c before = previous == null ? null : previous.get(r.Id);
            Boolean wasActive = before != null && before.Status__c == ACTIVE;
            if (wasActive && r.Status__c == ACTIVE && (r.Rule__c != before.Rule__c || r.Firm__c != before.Firm__c)) {
                r.addError('An Active rule cannot be edited. Set it back to Proposed to change it; it then needs activating again.');
                continue;
            }
            Boolean activating = r.Status__c == ACTIVE && (before == null || before.Status__c != ACTIVE);
            if (!activating) {
                if (wasActive && r.Status__c != ACTIVE) {
                    // Leaving Active clears the approval, so reactivating needs a fresh one.
                    r.Approved_By__c = null;
                    r.Approved_At__c = null;
                } else if (approvalEditedByHand(r, before)) {
                    r.addError('Approved By and Approved At are set by the system when a rule is activated.');
                }
                continue;
            }
            Id author = before == null ? me : before.CreatedById;
            if (twoPerson && author == me) {
                r.Status__c.addError('Someone other than the rule\'s author must activate it.');
                continue;
            }
            r.Approved_By__c = me;
            r.Approved_At__c = System.now();
        }
    }

    private static Boolean approvalEditedByHand(Matching_Rule__c r, Matching_Rule__c before) {
        if (before == null) {
            return r.Approved_By__c != null || r.Approved_At__c != null;
        }
        return r.Approved_By__c != before.Approved_By__c || r.Approved_At__c != before.Approved_At__c;
    }
}
