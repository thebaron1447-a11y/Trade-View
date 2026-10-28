/**
 * Applies a reviewer's decision on a staging row in Needs Review (Reviewer_Decision__c).
 *
 * Accept on a trade or AUM row: the Firm and Fund Overrides are used (filled from Claude's suggestion when left
 * blank), the row goes back to Pending and is re-matched. With Remember Choice, an unresolved firm or fund
 * spelling is saved as an alias so future files match it automatically.
 * Accept on a roster row: the roster entry is applied (RosterApprovalService) and the row is marked Matched.
 * Reject: the row is marked Rejected and never loaded.
 * Who decided and when is stamped on the row.
 */
public with sharing class ReviewDecisionService {
    public static final String ACCEPT = 'Accept';
    public static final String REJECT = 'Reject';
    public static final String REJECTED = 'Rejected';

    /** Before update: validate the decision and set the row's fields. No DML. */
    public static void beforeUpdate(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        Id me = UserInfo.getUserId();
        for (Import_Staging_Row__c row : decided(rows, previous)) {
            if (previous.get(row.Id).Match_Status__c != TradeMatcher.REVIEW) {
                row.Reviewer_Decision__c.addError('Only rows in Needs Review can be accepted or rejected.');
                continue;
            }
            row.Decided_By__c = me;
            row.Decided_At__c = System.now();
            // A decision ends any hold; who held it, when and why stay on the row for the record.
            row.On_Hold__c = false;
            if (row.Reviewer_Decision__c == REJECT) {
                row.Match_Status__c = REJECTED;
                continue;
            }
            Set<String> flags = ClaudeSuggestionService.flagSet(row.Match_Flags__c);
            Boolean needsFirm = !flagsIn(flags, ClaudeSuggestionService.FIRM_FLAGS).isEmpty();
            if (needsFirm && row.Firm_Override__c == null) {
                row.Firm_Override__c = row.AI_Suggested_Firm__c;
            }
            if (needsFirm && row.Firm_Override__c == null) {
                row.Firm_Override__c.addError('Choose a Firm Override, or wait for Claude to suggest one, before accepting.');
                continue;
            }
            if (row.Row_Type__c == TradeRowNormalizer.ROW_ROSTER) {
                if (row.Credited_Advisor__c == null && flags.contains('ADVISOR_AMBIGUOUS')) {
                    row.Credited_Advisor__c = row.AI_Suggested_Advisor__c;
                }
                if (row.Credited_Advisor__c == null && flags.contains('ADVISOR_AMBIGUOUS')) {
                    row.Credited_Advisor__c.addError(
                        'More than one advisor could be "' + row.Source_Advisor_Name__c + '". Choose the Credited Advisor before approving.'
                    );
                    continue;
                }
                // Applied in the after-update step; any failure there rolls this back.
                if (row.Firm_Override__c != null) {
                    row.Matched_Firm__c = row.Firm_Override__c;
                }
                row.Match_Status__c = TradeMatcher.MATCHED;
                row.Match_Method__c = 'Reviewer';
                continue;
            }
            if (flags.contains('ADVISOR_AMBIGUOUS')) {
                if (row.Advisor_Override__c == null) {
                    row.Advisor_Override__c = row.AI_Suggested_Advisor__c;
                }
                if (row.Advisor_Override__c == null) {
                    row.Advisor_Override__c.addError(
                        'More than one team member could be "' + row.Source_Advisor_Name__c + '". Choose the Advisor Override before accepting.'
                    );
                    continue;
                }
            }
            Boolean needsFund = !flagsIn(flags, ClaudeSuggestionService.FUND_FLAGS).isEmpty();
            if (needsFund && row.Fund_Override__c == null) {
                row.Fund_Override__c = row.AI_Suggested_Fund__c;
            }
            if (needsFund && row.Fund_Override__c == null) {
                row.Fund_Override__c.addError('Choose a Fund Override, or wait for Claude to suggest one, before accepting.');
                continue;
            }
            // Re-match with the overrides (or, for other review reasons, after the reviewer fixed the data).
            row.Match_Status__c = TradeMatcher.PENDING;
        }
    }

    /** After update: teach aliases, apply roster rows, and re-match accepted rows. */
    public static void afterUpdate(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        List<Import_Staging_Row__c> roster = new List<Import_Staging_Row__c>();
        List<Import_Staging_Row__c> rematch = new List<Import_Staging_Row__c>();
        for (Import_Staging_Row__c row : decided(rows, previous)) {
            if (row.Reviewer_Decision__c != ACCEPT) {
                continue;
            }
            if (row.Row_Type__c == TradeRowNormalizer.ROW_ROSTER) {
                roster.add(row);
            } else {
                rematch.add(row);
            }
        }
        if (!roster.isEmpty()) {
            RosterApprovalService.apply(roster);
        }
        if (rematch.isEmpty()) {
            return;
        }
        teachAliases(rematch);
        Set<Id> batchIds = new Set<Id>();
        for (Import_Staging_Row__c row : rematch) {
            batchIds.add(row.Import_Batch__c);
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new TradeMatcher(batchIds));
        }
    }

    /** Rows whose decision was just set (a change to blank, made when a row is re-matched, is ignored). */
    private static List<Import_Staging_Row__c> decided(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        List<Import_Staging_Row__c> result = new List<Import_Staging_Row__c>();
        for (Import_Staging_Row__c row : rows) {
            Import_Staging_Row__c before = previous.get(row.Id);
            if (row.Reviewer_Decision__c != null && (before == null || row.Reviewer_Decision__c != before.Reviewer_Decision__c)) {
                result.add(row);
            }
        }
        return result;
    }

    /**
     * Saves unresolved spellings as aliases when the reviewer asked to remember them. Ambiguous spellings are
     * never aliased: they match more than one record, so they must keep going to review.
     */
    private static void teachAliases(List<Import_Staging_Row__c> rows) {
        Map<String, Firm_Alias__c> firmAliases = new Map<String, Firm_Alias__c>();
        Map<String, Fund_Alias__c> fundAliases = new Map<String, Fund_Alias__c>();
        for (Import_Staging_Row__c row : rows) {
            if (row.Remember_Choice__c != true) {
                continue;
            }
            Set<String> flags = ClaudeSuggestionService.flagSet(row.Match_Flags__c);
            String firmKey = NameNormalizer.firmKey(row.Source_Firm_Name__c);
            if (flags.contains('FIRM_UNRESOLVED') && firmKey != null && row.Firm_Override__c != null) {
                firmAliases.put(
                    firmKey,
                    new Firm_Alias__c(Name = row.Source_Firm_Name__c.left(80), Normalized_Key__c = firmKey, Firm__c = row.Firm_Override__c)
                );
            }
            String fundKey = NameNormalizer.firmKey(row.Source_Fund_Name__c);
            if (flags.contains('FUND_UNRESOLVED') && fundKey != null && row.Fund_Override__c != null) {
                fundAliases.put(
                    fundKey,
                    new Fund_Alias__c(Name = row.Source_Fund_Name__c.left(80), Normalized_Key__c = fundKey, Fund__c = row.Fund_Override__c)
                );
            }
        }
        if (!firmAliases.isEmpty()) {
            for (Firm_Alias__c existing : [SELECT Normalized_Key__c FROM Firm_Alias__c WHERE Normalized_Key__c IN :firmAliases.keySet() WITH USER_MODE]) {
                firmAliases.remove(existing.Normalized_Key__c);
            }
            insert as user firmAliases.values();
        }
        if (!fundAliases.isEmpty()) {
            for (Fund_Alias__c existing : [SELECT Normalized_Key__c FROM Fund_Alias__c WHERE Normalized_Key__c IN :fundAliases.keySet() WITH USER_MODE]) {
                fundAliases.remove(existing.Normalized_Key__c);
            }
            insert as user fundAliases.values();
        }
    }

    private static Set<String> flagsIn(Set<String> flags, Set<String> wanted) {
        Set<String> result = new Set<String>(flags);
        result.retainAll(wanted);
        return result;
    }
}
