/**
 * The Code Follow-Up to-do list. Matching holds rows whose code is unknown, ended, dormant,
 * suspected reassigned or incompletely split, and this service keeps one follow-up per
 * source firm, code and reason, with live counts of what is waiting on it.
 *
 * When a person sets a follow-up to Resolved, its held rows are released and re-matched
 * automatically. Closed - No Action sends them to manual review instead.
 */
public with sharing class CodeFollowUpService {
    public static final String STATUS_OPEN = 'Open';
    public static final String STATUS_IN_PROGRESS = 'In Progress';
    public static final String STATUS_RESOLVED = 'Resolved';
    public static final String STATUS_CLOSED = 'Closed - No Action';

    /** What matching wants recorded for one held code. */
    public class Draft {
        public String key;
        public String codeValue;
        public Id repCodeId;
        public Id firmId;
        public String reason;
        public Date lastSeen;

        public Draft combine(Draft other) {
            if (other.lastSeen != null && (lastSeen == null || other.lastSeen > lastSeen)) {
                lastSeen = other.lastSeen;
            }
            if (repCodeId == null) {
                repCodeId = other.repCodeId;
            }
            return this;
        }
    }

    public static String keyFor(String sourceFirm, String codeValue, String reason) {
        return ((sourceFirm == null ? '' : sourceFirm.toUpperCase()) + '|' + codeValue + '|' + reason).left(255);
    }

    /**
     * Call after the row's Matched_Firm__c and Matched_Rep_Code__c are set. One follow-up per matched firm, code and
     * reason: a dealer file can cover several firms (Kestrel Inc. and Ltd.), and each firm's code is its own question.
     * The dealer code is used only when the firm is unknown.
     */
    public static Draft draftFor(String sourceFirm, Import_Staging_Row__c row, String reason) {
        Draft d = new Draft();
        d.key = keyFor(row.Matched_Firm__c != null ? String.valueOf(row.Matched_Firm__c) : sourceFirm, row.Source_Rep_Code__c, reason);
        d.codeValue = row.Source_Rep_Code__c;
        d.repCodeId = row.Matched_Rep_Code__c;
        d.firmId = row.Matched_Firm__c;
        d.reason = reason;
        d.lastSeen = row.Trade_Date__c;
        return d;
    }

    /**
     * Creates missing follow-ups and updates existing ones (a resolved or closed follow-up is reopened,
     * because new rows are waiting on it). Returns follow-up Ids by key.
     */
    public static Map<String, Id> saveDrafts(List<Draft> drafts) {
        Map<String, Id> idsByKey = new Map<String, Id>();
        if (drafts == null || drafts.isEmpty()) {
            return idsByKey;
        }
        Map<String, Draft> byKey = new Map<String, Draft>();
        for (Draft d : drafts) {
            byKey.put(d.key, d);
        }
        List<Code_Follow_Up__c> updates = new List<Code_Follow_Up__c>();
        for (Code_Follow_Up__c existing : [
            SELECT Id, Follow_Up_Key__c, Status__c, Last_Seen_Date__c, Rep_Code__c, Firm__c
            FROM Code_Follow_Up__c
            WHERE Follow_Up_Key__c IN :byKey.keySet()
            WITH USER_MODE
        ]) {
            Draft d = byKey.remove(existing.Follow_Up_Key__c);
            idsByKey.put(existing.Follow_Up_Key__c, existing.Id);
            Code_Follow_Up__c u = new Code_Follow_Up__c(Id = existing.Id);
            if (d.lastSeen != null && (existing.Last_Seen_Date__c == null || d.lastSeen > existing.Last_Seen_Date__c)) {
                u.Last_Seen_Date__c = d.lastSeen;
            }
            if (existing.Rep_Code__c == null && d.repCodeId != null) {
                u.Rep_Code__c = d.repCodeId;
            }
            if (existing.Firm__c == null && d.firmId != null) {
                u.Firm__c = d.firmId;
            }
            if (existing.Status__c == STATUS_RESOLVED || existing.Status__c == STATUS_CLOSED) {
                u.Status__c = STATUS_OPEN;
                // New rows are new evidence: ask Claude again rather than show the old suggestion.
                u.AI_Status__c = null;
                u.AI_Confidence__c = null;
                u.AI_Suggested_Advisor__c = null;
                u.AI_Request__c = null;
                u.AI_Homework__c = null;
                u.AI_Field_Suggestions__c = null;
                u.Suggested_Resolution__c = null;
            }
            updates.add(u);
        }
        List<Code_Follow_Up__c> inserts = new List<Code_Follow_Up__c>();
        for (Draft d : byKey.values()) {
            inserts.add(
                new Code_Follow_Up__c(
                    Follow_Up_Key__c = d.key,
                    Rep_Code_Value__c = d.codeValue,
                    Rep_Code__c = d.repCodeId,
                    Firm__c = d.firmId,
                    Reason__c = d.reason,
                    Status__c = STATUS_OPEN,
                    Last_Seen_Date__c = d.lastSeen
                )
            );
        }
        update as user updates;
        insert as user inserts;
        for (Code_Follow_Up__c c : inserts) {
            idsByKey.put(c.Follow_Up_Key__c, c.Id);
        }
        return idsByKey;
    }

    /** Recomputes held row count and held trade value for the given follow-ups. */
    public static void recount(Set<Id> followUpIds) {
        Set<Id> ids = new Set<Id>(followUpIds == null ? new Set<Id>() : followUpIds);
        ids.remove(null);
        if (ids.isEmpty()) {
            return;
        }
        Map<Id, Code_Follow_Up__c> updates = new Map<Id, Code_Follow_Up__c>();
        for (Id i : ids) {
            updates.put(i, new Code_Follow_Up__c(Id = i, Held_Row_Count__c = 0, Held_Amount__c = 0));
        }
        for (AggregateResult ar : [
            SELECT Code_Follow_Up__c fid, COUNT(Id) n
            FROM Import_Staging_Row__c
            WHERE Code_Follow_Up__c IN :ids AND Match_Status__c = 'Held'
            WITH USER_MODE
            GROUP BY Code_Follow_Up__c
        ]) {
            Integer n = (Integer) ar.get('n');
            updates.get((Id) ar.get('fid')).Held_Row_Count__c = n;
        }
        for (AggregateResult ar : [
            SELECT Code_Follow_Up__c fid, SUM(Amount__c) amt
            FROM Import_Staging_Row__c
            WHERE Code_Follow_Up__c IN :ids AND Match_Status__c = 'Held' AND Row_Type__c = 'Trade'
            WITH USER_MODE
            GROUP BY Code_Follow_Up__c
        ]) {
            Decimal amt = (Decimal) ar.get('amt');
            updates.get((Id) ar.get('fid')).Held_Amount__c = amt == null ? 0 : amt;
        }
        update as user updates.values();
    }

    /** After-update trigger handler: release or close held rows when a follow-up is resolved or closed. */
    public static void handleStatusChanges(List<Code_Follow_Up__c> updated, Map<Id, Code_Follow_Up__c> previous) {
        Set<Id> released = new Set<Id>();
        Set<Id> closed = new Set<Id>();
        for (Code_Follow_Up__c f : updated) {
            Code_Follow_Up__c before = previous.get(f.Id);
            if (before == null || f.Status__c == before.Status__c) {
                continue;
            }
            if (f.Status__c == STATUS_RESOLVED) {
                released.add(f.Id);
            } else if (f.Status__c == STATUS_CLOSED) {
                closed.add(f.Id);
            }
        }
        if (released.isEmpty() && closed.isEmpty()) {
            return;
        }
        Set<Id> all = new Set<Id>(released);
        all.addAll(closed);
        List<Import_Staging_Row__c> rows = [
            SELECT Id, Import_Batch__c, Code_Follow_Up__c, Match_Flags__c
            FROM Import_Staging_Row__c
            WHERE Code_Follow_Up__c IN :all AND Match_Status__c = 'Held'
            WITH USER_MODE
            LIMIT 10000
        ];
        // Fresh records with only the changed fields: user-mode DML rejects the queried batch master-detail.
        Set<Id> batchIds = new Set<Id>();
        List<Import_Staging_Row__c> changes = new List<Import_Staging_Row__c>();
        for (Import_Staging_Row__c row : rows) {
            Import_Staging_Row__c change = new Import_Staging_Row__c(Id = row.Id, Code_Follow_Up__c = null);
            if (released.contains(row.Code_Follow_Up__c)) {
                change.Match_Status__c = TradeMatcher.PENDING;
                batchIds.add(row.Import_Batch__c);
            } else {
                change.Match_Status__c = TradeMatcher.REVIEW;
                // Appended last and always kept: earlier whole flags are dropped if the list would be too long.
                List<String> flags = String.isBlank(row.Match_Flags__c) ? new List<String>() : row.Match_Flags__c.split(';');
                while (!flags.isEmpty() && String.join(flags, ';').length() + ';FOLLOW_UP_CLOSED'.length() > 255) {
                    flags.remove(flags.size() - 1);
                }
                flags.add('FOLLOW_UP_CLOSED');
                change.Match_Flags__c = String.join(flags, ';');
            }
            changes.add(change);
        }
        update as user changes;
        recount(all);
        if (!batchIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new TradeMatcher(batchIds));
        }
    }
}
