/**
 * Applies approved advisor code roster rows: the dealer has told us who holds a code from a given date.
 *   - The advisor is the matched one, or is created at the branch named in the file (else at the firm).
 *   - The code is created if it does not exist yet.
 *   - The current holder's assignment is ended the day before the roster date (source: Confirmed by Firm), and
 *     a 100% assignment starts for the new holder. Team codes are left to a person, because a roster row
 *     names one advisor and cannot say how a team's split should change.
 *   - Open follow-ups for that firm and code (unknown, ended, dormant or suspected reassigned) are resolved,
 *     which releases their held rows for re-matching.
 * Runs in the after-update step of the reviewer's decision; any error is reported on the row and undoes it.
 */
public with sharing class RosterApprovalService {
    public static final String END_SOURCE = 'Confirmed by Firm';
    private static final Set<String> RESOLVABLE = new Set<String>{
        TradeMatcher.REASON_UNKNOWN,
        TradeMatcher.REASON_ENDED,
        TradeMatcher.REASON_DORMANT,
        TradeMatcher.REASON_REASSIGNED
    };

    private class Plan {
        public Import_Staging_Row__c row;
        public Id firmId;
        public String code;
        public Contact newAdvisor;
        public Id advisorId;
        public Rep_Code__c newCode;
        public Rep_Code__c existingCode;
    }

    public static void apply(List<Import_Staging_Row__c> rows) {
        List<Plan> plans = new List<Plan>();
        Set<Id> firmIds = new Set<Id>();
        Set<String> codes = new Set<String>();
        Set<String> seen = new Set<String>();
        for (Import_Staging_Row__c row : rows) {
            Plan p = new Plan();
            p.row = row;
            p.firmId = row.Firm_Override__c != null ? row.Firm_Override__c : row.Matched_Firm__c;
            p.code = row.Source_Rep_Code__c;
            if (p.firmId == null) {
                row.addError('The firm for this roster row is not known. Set Firm Override before approving.');
                continue;
            }
            if (row.Trade_Date__c == null || String.isBlank(p.code)) {
                row.addError('A roster row needs a code and an effective date.');
                continue;
            }
            String key = p.firmId + '|' + p.code.toUpperCase();
            if (seen.contains(key)) {
                row.addError('Another roster row for code ' + p.code + ' is being approved at the same time. Approve them one at a time.');
                continue;
            }
            seen.add(key);
            firmIds.add(p.firmId);
            codes.add(p.code);
            plans.add(p);
        }
        if (plans.isEmpty()) {
            return;
        }

        // Existing codes with their current (open) assignments.
        Map<String, Rep_Code__c> existing = new Map<String, Rep_Code__c>();
        for (Rep_Code__c rc : [
            SELECT Id, Name, Firm__c,
                (SELECT Id, Advisor__c, Effective_Start_Date__c FROM Assignments__r WHERE Effective_End_Date__c = NULL)
            FROM Rep_Code__c
            WHERE Firm__c IN :firmIds AND Name IN :codes
            WITH USER_MODE
        ]) {
            existing.put(rc.Firm__c + '|' + rc.Name.toUpperCase(), rc);
        }
        Map<String, Id> branchByName = branches(firmIds);

        List<Contact> newContacts = new List<Contact>();
        List<Rep_Code__c> newCodes = new List<Rep_Code__c>();
        List<Rep_Code_Assignment__c> endings = new List<Rep_Code_Assignment__c>();
        List<Plan> ready = new List<Plan>();
        for (Plan p : plans) {
            p.existingCode = existing.get(p.firmId + '|' + p.code.toUpperCase());
            p.advisorId = p.row.Credited_Advisor__c;
            if (p.existingCode != null) {
                List<Rep_Code_Assignment__c> open = p.existingCode.Assignments__r;
                Boolean alreadyHolder = false;
                for (Rep_Code_Assignment__c a : open) {
                    alreadyHolder = alreadyHolder || (p.advisorId != null && a.Advisor__c == p.advisorId);
                }
                if (alreadyHolder) {
                    p.row.addError('This advisor already holds code ' + p.code + '. Reject the row instead.');
                    continue;
                }
                if (open.size() > 1) {
                    p.row.addError('Code ' + p.code + ' is shared by a team. Update the team split by hand, then reject this row.');
                    continue;
                }
                if (open.size() == 1) {
                    if (open[0].Effective_Start_Date__c >= p.row.Trade_Date__c) {
                        p.row.addError('The roster date is not after the current holder\'s start date. Check the dates with the dealer.');
                        continue;
                    }
                    endings.add(
                        new Rep_Code_Assignment__c(Id = open[0].Id, Effective_End_Date__c = p.row.Trade_Date__c.addDays(-1), End_Date_Source__c = END_SOURCE)
                    );
                }
            } else {
                p.newCode = new Rep_Code__c(Name = p.code, Firm__c = p.firmId);
                newCodes.add(p.newCode);
            }
            if (p.advisorId == null) {
                p.newAdvisor = newContact(p.row, p.firmId, branchByName);
                newContacts.add(p.newAdvisor);
            }
            ready.add(p);
        }
        if (ready.isEmpty()) {
            return;
        }

        insert as user newContacts;
        insert as user newCodes;
        // End the old share before adding the new one: a code allows at most 100% across open assignments.
        update as user endings;
        List<Rep_Code_Assignment__c> starts = new List<Rep_Code_Assignment__c>();
        Map<String, Plan> byFirmAndCode = new Map<String, Plan>();
        for (Plan p : ready) {
            Id advisor = p.newAdvisor != null ? p.newAdvisor.Id : p.advisorId;
            Id codeId = p.newCode != null ? p.newCode.Id : p.existingCode.Id;
            starts.add(
                new Rep_Code_Assignment__c(Rep_Code__c = codeId, Advisor__c = advisor, Allocation_Percent__c = 100, Effective_Start_Date__c = p.row.Trade_Date__c)
            );
            byFirmAndCode.put(p.firmId + '|' + p.code.toUpperCase(), p);
        }
        insert as user starts;
        resolveFollowUps(firmIds, codes, byFirmAndCode);
    }

    private static void resolveFollowUps(Set<Id> firmIds, Set<String> codes, Map<String, Plan> byFirmAndCode) {
        List<Code_Follow_Up__c> resolutions = new List<Code_Follow_Up__c>();
        for (Code_Follow_Up__c fu : [
            SELECT Id, Firm__c, Rep_Code_Value__c
            FROM Code_Follow_Up__c
            WHERE Firm__c IN :firmIds AND Rep_Code_Value__c IN :codes AND Status__c IN ('Open', 'In Progress') AND Reason__c IN :RESOLVABLE
            WITH USER_MODE
        ]) {
            Plan p = byFirmAndCode.get(fu.Firm__c + '|' + fu.Rep_Code_Value__c.toUpperCase());
            if (p == null) {
                continue;
            }
            resolutions.add(
                new Code_Follow_Up__c(
                    Id = fu.Id,
                    Status__c = CodeFollowUpService.STATUS_RESOLVED,
                    Rep_Code__c = p.newCode != null ? p.newCode.Id : p.existingCode.Id,
                    Resolution_Notes__c = (
                        'Resolved by approving roster row ' + p.row.Name + ': ' + p.row.Source_Advisor_Name__c + ' holds code ' + p.code +
                        ' from ' + p.row.Trade_Date__c.format() + '.'
                    ).abbreviate(5000)
                )
            );
        }
        // The follow-up trigger releases the held rows and queues re-matching.
        update as user resolutions;
    }

    /** Branch Accounts under these firms by lower-cased name. */
    private static Map<String, Id> branches(Set<Id> firmIds) {
        Map<String, Id> result = new Map<String, Id>();
        for (Account b : [SELECT Id, Name, ParentId FROM Account WHERE ParentId IN :firmIds WITH USER_MODE]) {
            result.put(b.ParentId + '|' + b.Name.toLowerCase(), b.Id);
        }
        return result;
    }

    /** A Contact for a new advisor, at the named branch when it exists, otherwise at the firm. */
    @TestVisible
    private static Contact newContact(Import_Staging_Row__c row, Id firmId, Map<String, Id> branchByName) {
        List<String> parts = row.Source_Advisor_Name__c.normalizeSpace().split(' ');
        String lastName = parts.remove(parts.size() - 1);
        String firstName = parts.isEmpty() ? null : String.join(parts, ' ');
        Id accountId = firmId;
        if (String.isNotBlank(row.Source_Branch_Name__c)) {
            Id branch = branchByName.get(firmId + '|' + row.Source_Branch_Name__c.trim().toLowerCase());
            accountId = branch == null ? firmId : branch;
        }
        return new Contact(FirstName = firstName, LastName = lastName, AccountId = accountId);
    }
}
