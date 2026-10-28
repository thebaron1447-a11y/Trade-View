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
            SELECT Id, Name, Firm__c, (SELECT Id, Advisor__c, Effective_Start_Date__c FROM Assignments__r WHERE Effective_End_Date__c = NULL)
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
                new Rep_Code_Assignment__c(
                    Rep_Code__c = codeId,
                    Advisor__c = advisor,
                    Allocation_Percent__c = 100,
                    Effective_Start_Date__c = p.row.Trade_Date__c
                )
            );
            byFirmAndCode.put(p.firmId + '|' + p.code.toUpperCase(), p);
        }
        insert as user starts;
        resolveFollowUps(firmIds, codes, byFirmAndCode);
    }

    /**
     * What approving each roster row would do, in plain words, without changing anything. Uses the same rules as
     * apply(): a row that cannot be approved gets one line starting "Cannot approve:" with the reason apply() gives.
     * Rows need: Id, Firm_Override__c, Matched_Firm__c, Source_Rep_Code__c, Source_Advisor_Name__c,
     * Source_Branch_Name__c, Trade_Date__c, Credited_Advisor__c and Credited_Advisor__r.Name.
     */
    public static Map<Id, List<String>> preview(List<Import_Staging_Row__c> rows) {
        Map<Id, List<String>> result = new Map<Id, List<String>>();
        Set<Id> firmIds = new Set<Id>();
        Set<String> codes = new Set<String>();
        for (Import_Staging_Row__c row : rows) {
            Id firmId = row.Firm_Override__c != null ? row.Firm_Override__c : row.Matched_Firm__c;
            if (firmId != null && String.isNotBlank(row.Source_Rep_Code__c)) {
                firmIds.add(firmId);
                codes.add(row.Source_Rep_Code__c);
            }
        }
        Map<String, Rep_Code__c> existing = new Map<String, Rep_Code__c>();
        Map<String, Code_Follow_Up__c> followUps = new Map<String, Code_Follow_Up__c>();
        Map<Id, String> accountNames = new Map<Id, String>();
        Map<String, Id> branchByName = new Map<String, Id>();
        if (!firmIds.isEmpty()) {
            for (Rep_Code__c rc : [
                SELECT
                    Id,
                    Name,
                    Firm__c,
                    (SELECT Id, Advisor__c, Advisor__r.Name, Effective_Start_Date__c FROM Assignments__r WHERE Effective_End_Date__c = NULL)
                FROM Rep_Code__c
                WHERE Firm__c IN :firmIds AND Name IN :codes
                WITH USER_MODE
            ]) {
                existing.put(rc.Firm__c + '|' + rc.Name.toUpperCase(), rc);
            }
            for (Code_Follow_Up__c fu : [
                SELECT Firm__c, Rep_Code_Value__c, Held_Row_Count__c
                FROM Code_Follow_Up__c
                WHERE Firm__c IN :firmIds AND Rep_Code_Value__c IN :codes AND Status__c IN ('Open', 'In Progress') AND Reason__c IN :RESOLVABLE
                WITH USER_MODE
            ]) {
                followUps.put(fu.Firm__c + '|' + fu.Rep_Code_Value__c.toUpperCase(), fu);
            }
            for (Account a : [SELECT Id, Name FROM Account WHERE Id IN :firmIds OR ParentId IN :firmIds WITH USER_MODE]) {
                accountNames.put(a.Id, a.Name);
            }
            branchByName = branches(firmIds);
        }
        for (Import_Staging_Row__c row : rows) {
            result.put(row.Id, previewOne(row, existing, followUps, accountNames, branchByName));
        }
        return result;
    }

    private static List<String> previewOne(
        Import_Staging_Row__c row,
        Map<String, Rep_Code__c> existing,
        Map<String, Code_Follow_Up__c> followUps,
        Map<Id, String> accountNames,
        Map<String, Id> branchByName
    ) {
        Id firmId = row.Firm_Override__c != null ? row.Firm_Override__c : row.Matched_Firm__c;
        if (firmId == null) {
            return new List<String>{ 'Cannot approve: the firm for this roster row is not known. Choose the firm first.' };
        }
        if (row.Trade_Date__c == null || String.isBlank(row.Source_Rep_Code__c)) {
            return new List<String>{ 'Cannot approve: a roster row needs a code and an effective date.' };
        }
        String code = row.Source_Rep_Code__c;
        String key = firmId + '|' + code.toUpperCase();
        List<String> lines = new List<String>();
        String advisorName = row.Credited_Advisor__r?.Name;
        if (row.Credited_Advisor__c == null) {
            Contact c = newContact(row, firmId, branchByName);
            advisorName = ((c.FirstName == null ? '' : c.FirstName + ' ') + c.LastName).trim();
            lines.add('Create advisor ' + advisorName + ' at ' + accountNames.get(c.AccountId));
        }
        Rep_Code__c rc = existing.get(key);
        if (rc == null) {
            lines.add('Create code ' + code + ' at ' + accountNames.get(firmId));
        } else {
            List<Rep_Code_Assignment__c> open = rc.Assignments__r;
            for (Rep_Code_Assignment__c a : open) {
                if (row.Credited_Advisor__c != null && a.Advisor__c == row.Credited_Advisor__c) {
                    return new List<String>{ 'Cannot approve: this advisor already holds code ' + code + '. Reject the row instead.' };
                }
            }
            if (open.size() > 1) {
                return new List<String>{ 'Cannot approve: code ' + code + ' is shared by a team. Update the team split by hand, then reject this row.' };
            }
            if (open.size() == 1) {
                if (open[0].Effective_Start_Date__c >= row.Trade_Date__c) {
                    return new List<String>{
                        'Cannot approve: the roster date is not after the current holder\'s start date. Check the dates with the dealer.'
                    };
                }
                lines.add('End ' + open[0].Advisor__r?.Name + '\'s assignment on ' + String.valueOf(row.Trade_Date__c.addDays(-1)));
            }
        }
        lines.add('Assign code ' + code + ' 100% to ' + advisorName + ' from ' + String.valueOf(row.Trade_Date__c));
        Code_Follow_Up__c fu = followUps.get(key);
        if (fu != null) {
            Integer held = fu.Held_Row_Count__c == null ? 0 : fu.Held_Row_Count__c.intValue();
            lines.add('Close the code review for ' + code + ' and re-match its ' + held + (held == 1 ? ' held trade' : ' held trades'));
        }
        return lines;
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
                    Resolution_Notes__c = ('Resolved by approving roster row ' +
                        p.row.Name +
                        ': ' +
                        p.row.Source_Advisor_Name__c +
                        ' holds code ' +
                        p.code +
                        ' from ' +
                        p.row.Trade_Date__c.format() +
                        '.')
                        .abbreviate(5000)
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
