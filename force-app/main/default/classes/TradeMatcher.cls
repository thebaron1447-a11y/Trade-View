/**
 * Deterministic matching (tiers 1 and 2) for staged rows. For each Pending row it resolves the firm,
 * the rep code, who gets the credit, and the fund, then marks the row:
 *   Matched       everything resolved without doubt
 *   Needs Review  a name is ambiguous or unresolved (Claude suggests, a reviewer decides)
 *   Held          the code is unknown, ended, dormant, suspected reassigned or incompletely split;
 *                 the row waits on a Code Follow-Up and is never orphaned
 * Code Roster rows are classified (confirms an existing holder, new holder, or new code) for review.
 *
 * Re-running is safe: only Pending rows are processed, and resolving a follow-up sets its rows back to Pending.
 * A reviewer's Firm or Fund Override (set directly or by accepting Claude's suggestion) replaces name matching.
 * After each run, ClaudeSuggestionJob is queued for anything left in Needs Review or on a follow-up.
 */
public with sharing class TradeMatcher implements Queueable {
    public static final String MATCHED = 'Matched';
    public static final String REVIEW = 'Needs Review';
    public static final String HELD = 'Held';
    public static final String PENDING = 'Pending';
    public static final String STATUS_PENDING_REVIEW = 'Pending Review';

    public static final String REASON_UNKNOWN = 'Unknown Code';
    public static final String REASON_ENDED = 'Code Ended';
    public static final String REASON_DORMANT = 'Code Dormant';
    public static final String REASON_REASSIGNED = 'Reassignment Suspected';
    public static final String REASON_ALLOCATION = 'Allocation Incomplete';

    @TestVisible
    private static final Integer DORMANCY_DAYS = 180;
    /** Flags about the rep code itself. Rows with any of them (and roster rows) are worked in Dealer Code Review. */
    public static final Set<String> CODE_FLAGS = new Set<String>{
        'ROSTER_NEW_HOLDER',
        'ROSTER_NEW_CODE',
        'ADVISOR_AMBIGUOUS',
        'UNKNOWN_CODE',
        'CODE_ENDED',
        'DATE_BEFORE_CODE_START',
        'DORMANT_CODE_REACTIVATED',
        'DORMANT_CODE_NO_NAME',
        'REASSIGNMENT_SUSPECTED',
        'TEAM_CHANGE_SUSPECTED',
        'ALLOCATION_INCOMPLETE',
        'FOLLOW_UP_CLOSED'
    };
    /** Firm and fund issues that rows can share. A missing or ambiguous name also depends on the code. */
    private static final List<String> SHARED_ISSUES = new List<String>{
        'FIRM_MISSING',
        'FIRM_UNRESOLVED',
        'FIRM_AMBIGUOUS',
        'FUND_UNRESOLVED',
        'FUND_AMBIGUOUS'
    };
    // A fuzzy name match is accepted only if it is very close and clearly better than the next option.
    @TestVisible
    private static final Decimal AUTO_ACCEPT = 0.9;
    @TestVisible
    private static final Decimal MARGIN = 0.1;
    private static final Integer MAX_CANDIDATES = 3;

    private final Set<Id> batchIds;

    public TradeMatcher(Set<Id> batchIds) {
        this.batchIds = batchIds;
    }

    public void execute(QueueableContext context) {
        run(batchIds);
    }

    // ================================================================== orchestration

    public static void run(Set<Id> batchIds) {
        Map<Id, Import_Batch__c> batches = new Map<Id, Import_Batch__c>(
            [
                SELECT Id, Status__c, Source_Firm__c
                FROM Import_Batch__c
                WHERE Id IN :batchIds AND Status__c IN ('Staged', 'Pending Review')
                WITH USER_MODE
            ]
        );
        if (batches.isEmpty()) {
            return;
        }
        List<Import_Staging_Row__c> rows = [
            SELECT
                Id,
                Import_Batch__c,
                Row_Type__c,
                Source_Rep_Code__c,
                Source_Advisor_Name__c,
                Source_Firm_Name__c,
                Source_Fund_Name__c,
                Trade_Date__c,
                Amount__c,
                Code_Follow_Up__c,
                Firm_Override__c,
                Fund_Override__c,
                AI_Suggested_Firm__c,
                AI_Suggested_Fund__c,
                Advisor_Override__c
            FROM Import_Staging_Row__c
            WHERE Import_Batch__c IN :batches.keySet() AND Has_Errors__c = FALSE AND (Match_Status__c = 'Pending' OR Match_Status__c = NULL)
            WITH USER_MODE
            ORDER BY Import_Batch__c, Row_Number__c
            LIMIT 10000
        ];

        Set<Id> touchedFollowUps = new Set<Id>();
        if (!rows.isEmpty()) {
            Reference ref = new Reference(rows);
            Map<String, CodeFollowUpService.Draft> drafts = new Map<String, CodeFollowUpService.Draft>();
            Map<Id, String> heldKeyByRow = new Map<Id, String>();
            Map<Id, Date> confirmedOn = new Map<Id, Date>();
            for (Import_Staging_Row__c row : rows) {
                if (row.Code_Follow_Up__c != null) {
                    touchedFollowUps.add(row.Code_Follow_Up__c);
                }
                String sourceFirm = batches.get(row.Import_Batch__c).Source_Firm__c;
                Outcome o = row.Row_Type__c == TradeRowNormalizer.ROW_ROSTER ? matchRoster(row, ref) : matchActivity(row, ref);
                apply(row, o);
                if (o.status == MATCHED && row.Row_Type__c == TradeRowNormalizer.ROW_TRADE && row.Trade_Date__c != null) {
                    for (Id a : o.confirmed) {
                        Date latest = confirmedOn.get(a);
                        if (latest == null || row.Trade_Date__c > latest) {
                            confirmedOn.put(a, row.Trade_Date__c);
                        }
                    }
                }
                row.Issue_Key__c = issueKey(sourceFirm, row, o);
                if (o.status == HELD) {
                    CodeFollowUpService.Draft d = CodeFollowUpService.draftFor(sourceFirm, row, o.reason);
                    CodeFollowUpService.Draft existing = drafts.get(d.key);
                    drafts.put(d.key, existing == null ? d : existing.combine(d));
                    heldKeyByRow.put(row.Id, d.key);
                }
            }
            Map<String, Id> followUpIds = CodeFollowUpService.saveDrafts(drafts.values());
            // User-mode DML checks edit access on every populated field. The queried rows carry the batch
            // master-detail and source fields, which matching must not write, so only the results are sent.
            List<Import_Staging_Row__c> results = new List<Import_Staging_Row__c>();
            for (Import_Staging_Row__c row : rows) {
                String key = heldKeyByRow.get(row.Id);
                Import_Staging_Row__c result = matchResult(row);
                result.Code_Follow_Up__c = key == null ? null : followUpIds.get(key);
                results.add(result);
            }
            update as user results;
            recordConfirmedActivity(confirmedOn);
            touchedFollowUps.addAll(followUpIds.values());
        }
        CodeFollowUpService.recount(touchedFollowUps);

        List<Import_Batch__c> statusUpdates = new List<Import_Batch__c>();
        for (Import_Batch__c b : batches.values()) {
            if (b.Status__c != STATUS_PENDING_REVIEW) {
                statusUpdates.add(new Import_Batch__c(Id = b.Id, Status__c = STATUS_PENDING_REVIEW));
            }
        }
        update as user statusUpdates;
        queueSuggestions(batches.keySet());
    }

    /**
     * Moves each credited assignment's Last Confirmed Trade Date forward to its latest matched trade, so a code in
     * use never drifts into "dormant". This one field is written in system mode: it is bookkeeping owned by matching,
     * and the integration user (who runs matching) has no edit access to assignments, which hold commission splits.
     */
    @TestVisible
    private static void recordConfirmedActivity(Map<Id, Date> confirmedOn) {
        if (confirmedOn.isEmpty()) {
            return;
        }
        List<Rep_Code_Assignment__c> changes = new List<Rep_Code_Assignment__c>();
        for (Rep_Code_Assignment__c a : [
            SELECT Id, Last_Confirmed_Trade_Date__c
            FROM Rep_Code_Assignment__c
            WHERE Id IN :confirmedOn.keySet()
            WITH USER_MODE
        ]) {
            Date latest = confirmedOn.get(a.Id);
            if (a.Last_Confirmed_Trade_Date__c == null || latest > a.Last_Confirmed_Trade_Date__c) {
                changes.add(new Rep_Code_Assignment__c(Id = a.Id, Last_Confirmed_Trade_Date__c = latest));
            }
        }
        Database.update(changes, AccessLevel.SYSTEM_MODE);
    }

    /** Claude looks at whatever matching could not settle. Tests call ClaudeSuggestionJob directly. */
    private static void queueSuggestions(Set<Id> batchIds) {
        if (AiSettings.get().enabled && !Test.isRunningTest() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new ClaudeSuggestionJob(batchIds));
        }
    }

    // ================================================================== matching rules

    @TestVisible
    private class Outcome {
        public String status = MATCHED;
        public String reason;
        public String method = 'Exact';
        public Id firmId;
        public Id repCodeId;
        public Id fundId;
        public Id creditedAdvisorId;
        public List<String> flags = new List<String>();
        public List<String> notes = new List<String>();
        public List<Map<String, Object>> candidates = new List<Map<String, Object>>();
        /** Assignments this row confirms as active on its date (credited holders), for the dormancy check. */
        public Set<Id> confirmed = new Set<Id>();

        public void hold(String holdReason, String code, String note) {
            this.status = HELD;
            this.reason = holdReason;
            flag(code, note);
        }

        public void review(String code, String note) {
            if (this.status != HELD) {
                this.status = REVIEW;
            }
            flag(code, note);
        }

        public void flag(String code, String note) {
            if (code != null) {
                flags.add(code);
            }
            if (note != null) {
                notes.add(note);
            }
        }
    }

    @TestVisible
    private static Outcome matchActivity(Import_Staging_Row__c row, Reference ref) {
        Outcome o = new Outcome();
        if (!resolveFirm(row, ref, o)) {
            return o;
        }
        Rep_Code__c code = ref.code(o.firmId, row.Source_Rep_Code__c);
        if (code == null) {
            o.hold(REASON_UNKNOWN, 'UNKNOWN_CODE', 'Code ' + row.Source_Rep_Code__c + ' is not set up for this firm.');
            resolveFund(row, ref, o);
            return o;
        }
        o.repCodeId = code.Id;

        List<Rep_Code_Assignment__c> active = activeOn(code, row.Trade_Date__c);
        if (active.isEmpty()) {
            if (endedBefore(code, row.Trade_Date__c)) {
                o.hold(REASON_ENDED, 'CODE_ENDED', 'Every assignment on code ' + code.Name + ' ended before ' + row.Trade_Date__c.format() + '.');
            } else {
                o.review('DATE_BEFORE_CODE_START', 'The row date is before anyone held code ' + code.Name + '.');
            }
            resolveFund(row, ref, o);
            return o;
        }

        String name = row.Source_Advisor_Name__c;
        Boolean named = String.isNotBlank(name);
        List<Rep_Code_Assignment__c> compatible = new List<Rep_Code_Assignment__c>();
        if (named) {
            for (Rep_Code_Assignment__c a : active) {
                if (NameMatcher.isCompatible(name, a.Advisor__r.FirstName, a.Advisor__r.LastName)) {
                    compatible.add(a);
                }
            }
        }
        Boolean team = active.size() > 1;
        // A reviewer who chose the team member to credit settles it, as long as that person holds the code on the date.
        if (row.Advisor_Override__c != null) {
            for (Rep_Code_Assignment__c a : active) {
                if (a.Advisor__c == row.Advisor_Override__c) {
                    o.creditedAdvisorId = a.Advisor__c;
                    o.confirmed.add(a.Id);
                    o.flag('ADVISOR_FROM_REVIEWER', '100% credited to ' + fullName(a) + ', chosen by a reviewer.');
                    resolveFund(row, ref, o);
                    return o;
                }
            }
        }
        Boolean dormant = isDormant(active, row.Trade_Date__c);

        if (named && compatible.isEmpty()) {
            o.hold(
                REASON_REASSIGNED,
                team ? 'TEAM_CHANGE_SUSPECTED' : 'REASSIGNMENT_SUSPECTED',
                '"' + name + '" does not match ' + (team ? 'any current member of team code ' : 'the current holder of code ') + code.Name + '.'
            );
        } else if (!named && dormant) {
            o.hold(
                REASON_DORMANT,
                'DORMANT_CODE_NO_NAME',
                'Code ' + code.Name + ' has had no confirmed activity for over ' + DORMANCY_DAYS + ' days and the row names no advisor.'
            );
        } else {
            if (dormant) {
                o.flag('DORMANT_CODE_REACTIVATED', 'Code ' + code.Name + ' was dormant, but the advisor name confirms the current holder.');
            }
            if (team && compatible.size() > 1 && compatible.size() < active.size()) {
                // The name fits some members but not all (a shared surname, an initial): splitting across the whole
                // team would credit people the name rules out, so a person chooses.
                List<String> names = new List<String>();
                List<Map<String, Object>> people = new List<Map<String, Object>>();
                for (Rep_Code_Assignment__c a : compatible) {
                    names.add(fullName(a));
                    people.add(new Map<String, Object>{ 'id' => a.Advisor__c, 'name' => fullName(a), 'score' => 1 });
                }
                o.review(
                    'ADVISOR_AMBIGUOUS',
                    '"' + name + '" fits more than one member of team code ' + code.Name + ': ' + String.join(names, ', ') + '. Choose who to credit.'
                );
                addCandidates(o, 'advisor', people);
            } else if (compatible.size() == 1) {
                o.creditedAdvisorId = compatible[0].Advisor__c;
                o.confirmed.add(compatible[0].Id);
                if (team) {
                    o.flag('SINGLE_ADVISOR_CREDIT', 'Row names one team member: 100% credited to ' + fullName(compatible[0]) + '.');
                }
            } else if (!team) {
                o.creditedAdvisorId = active[0].Advisor__c;
                o.confirmed.add(active[0].Id);
            } else if (totalPercent(active) != 100) {
                o.hold(
                    REASON_ALLOCATION,
                    'ALLOCATION_INCOMPLETE',
                    'Team code ' + code.Name + ' has active shares totalling ' + totalPercent(active).stripTrailingZeros().toPlainString() + '%, not 100%.'
                );
            } else {
                o.flag('TEAM_SPLIT', 'Split across team code ' + code.Name + ' by its percentages.');
                for (Rep_Code_Assignment__c a : active) {
                    o.confirmed.add(a.Id);
                }
            }
        }
        resolveFund(row, ref, o);
        return o;
    }

    @TestVisible
    private static Outcome matchRoster(Import_Staging_Row__c row, Reference ref) {
        Outcome o = new Outcome();
        if (!resolveFirm(row, ref, o)) {
            return o;
        }
        List<Contact> people = new List<Contact>();
        for (Contact c : ref.contactsAtFirm(o.firmId)) {
            if (NameMatcher.isCompatible(row.Source_Advisor_Name__c, c.FirstName, c.LastName)) {
                people.add(c);
            }
        }
        if (people.size() == 1) {
            o.creditedAdvisorId = people[0].Id;
        } else if (people.isEmpty()) {
            o.flag('NEW_ADVISOR', 'No advisor named "' + row.Source_Advisor_Name__c + '" exists at this firm yet.');
        } else {
            o.flag('ADVISOR_AMBIGUOUS', 'More than one advisor at this firm could be "' + row.Source_Advisor_Name__c + '".');
        }

        Rep_Code__c code = ref.code(o.firmId, row.Source_Rep_Code__c);
        if (code == null) {
            o.review('ROSTER_NEW_CODE', 'Code ' + row.Source_Rep_Code__c + ' is new: approving this row sets it up.');
            return o;
        }
        o.repCodeId = code.Id;
        for (Rep_Code_Assignment__c a : code.Assignments__r) {
            if (a.Effective_End_Date__c == null && NameMatcher.isCompatible(row.Source_Advisor_Name__c, a.Advisor__r.FirstName, a.Advisor__r.LastName)) {
                o.flag('ROSTER_CONFIRMS', 'Confirms ' + fullName(a) + ' as a current holder of code ' + code.Name + '.');
                return o;
            }
        }
        o.review(
            'ROSTER_NEW_HOLDER',
            'Code ' + code.Name + ' is listed for "' + row.Source_Advisor_Name__c + '", who is not a current holder: approving ends the old assignment.'
        );
        return o;
    }

    // ================================================================== resolution helpers

    private static Boolean resolveFirm(Import_Staging_Row__c row, Reference ref, Outcome o) {
        if (row.Firm_Override__c != null) {
            Boolean fromClaude = row.Firm_Override__c == row.AI_Suggested_Firm__c;
            o.firmId = row.Firm_Override__c;
            o.method = fromClaude ? 'Claude' : 'Reviewer';
            o.flag(
                fromClaude ? 'FIRM_FROM_CLAUDE' : 'FIRM_FROM_REVIEWER',
                'Firm set by a reviewer' + (fromClaude ? ' who accepted Claude\'s suggestion.' : '.')
            );
            return true;
        }
        String key = NameNormalizer.firmKey(row.Source_Firm_Name__c);
        if (key == null) {
            o.review('FIRM_MISSING', 'The row has no firm name and the feed is not a single-firm feed.');
            return false;
        }
        Resolution r = ref.resolve(key, ref.firmIdsByKey, ref.firmAliasKeys, ref.firmNames);
        if (r.id == null) {
            o.review(
                r.ambiguous ? 'FIRM_AMBIGUOUS' : 'FIRM_UNRESOLVED',
                r.ambiguous
                    ? 'Firm name "' + row.Source_Firm_Name__c + '" matches more than one firm.'
                    : 'Firm name "' + row.Source_Firm_Name__c + '" does not match any known firm.'
            );
            addCandidates(o, 'firm', r.candidates);
            return false;
        }
        o.firmId = r.id;
        if (r.fuzzy) {
            o.method = 'Fuzzy';
            o.flag('FIRM_FUZZY', 'Firm "' + row.Source_Firm_Name__c + '" matched to ' + ref.firmNames.get(r.id) + ' by close spelling.');
        }
        return true;
    }

    private static void resolveFund(Import_Staging_Row__c row, Reference ref, Outcome o) {
        if (row.Fund_Override__c != null) {
            Boolean fromClaude = row.Fund_Override__c == row.AI_Suggested_Fund__c;
            o.fundId = row.Fund_Override__c;
            if (o.method != 'Claude') {
                o.method = fromClaude ? 'Claude' : 'Reviewer';
            }
            o.flag(
                fromClaude ? 'FUND_FROM_CLAUDE' : 'FUND_FROM_REVIEWER',
                'Fund set by a reviewer' + (fromClaude ? ' who accepted Claude\'s suggestion.' : '.')
            );
            return;
        }
        String key = NameNormalizer.firmKey(row.Source_Fund_Name__c);
        if (key == null) {
            return; // AUM total per code; Trade rows without a fund never reach matching.
        }
        Resolution r = ref.resolve(key, ref.fundIdsByKey, ref.fundAliasKeys, ref.fundNames);
        if (r.id == null) {
            o.review(r.ambiguous ? 'FUND_AMBIGUOUS' : 'FUND_UNRESOLVED', 'Fund name "' + row.Source_Fund_Name__c + '" could not be matched to a single fund.');
            addCandidates(o, 'fund', r.candidates);
            return;
        }
        o.fundId = r.id;
        if (r.fuzzy) {
            o.method = 'Fuzzy';
            o.flag('FUND_FUZZY', 'Fund "' + row.Source_Fund_Name__c + '" matched to ' + ref.fundNames.get(r.id) + ' by close spelling.');
        }
    }

    private static void addCandidates(Outcome o, String kind, List<Map<String, Object>> found) {
        for (Map<String, Object> c : found) {
            c.put('type', kind);
            o.candidates.add(c);
        }
    }

    @TestVisible
    private static List<Rep_Code_Assignment__c> activeOn(Rep_Code__c code, Date d) {
        List<Rep_Code_Assignment__c> active = new List<Rep_Code_Assignment__c>();
        for (Rep_Code_Assignment__c a : code.Assignments__r) {
            if (a.Effective_Start_Date__c <= d && (a.Effective_End_Date__c == null || a.Effective_End_Date__c >= d)) {
                active.add(a);
            }
        }
        return active;
    }

    private static Boolean endedBefore(Rep_Code__c code, Date d) {
        for (Rep_Code_Assignment__c a : code.Assignments__r) {
            if (a.Effective_End_Date__c != null && a.Effective_End_Date__c < d) {
                return true;
            }
        }
        return false;
    }

    @TestVisible
    private static Boolean isDormant(List<Rep_Code_Assignment__c> active, Date d) {
        Date latest;
        for (Rep_Code_Assignment__c a : active) {
            if (a.Last_Confirmed_Trade_Date__c != null && (latest == null || a.Last_Confirmed_Trade_Date__c > latest)) {
                latest = a.Last_Confirmed_Trade_Date__c;
            }
        }
        return latest != null && latest.daysBetween(d) > DORMANCY_DAYS;
    }

    private static Decimal totalPercent(List<Rep_Code_Assignment__c> active) {
        Decimal total = 0;
        for (Rep_Code_Assignment__c a : active) {
            total += a.Allocation_Percent__c == null ? 0 : a.Allocation_Percent__c;
        }
        return total;
    }

    private static String fullName(Rep_Code_Assignment__c a) {
        return ((a.Advisor__r.FirstName == null ? '' : a.Advisor__r.FirstName + ' ') + a.Advisor__r.LastName).trim();
    }

    /** A record holding only the fields matching writes, for user-mode update. */
    @TestVisible
    private static Import_Staging_Row__c matchResult(Import_Staging_Row__c row) {
        Import_Staging_Row__c result = new Import_Staging_Row__c(
            Id = row.Id,
            Match_Status__c = row.Match_Status__c,
            Match_Method__c = row.Match_Method__c,
            Matched_Firm__c = row.Matched_Firm__c,
            Matched_Rep_Code__c = row.Matched_Rep_Code__c,
            Matched_Fund__c = row.Matched_Fund__c,
            Credited_Advisor__c = row.Credited_Advisor__c,
            Match_Flags__c = row.Match_Flags__c,
            Match_Notes__c = row.Match_Notes__c,
            Match_Candidates__c = row.Match_Candidates__c,
            Issue_Key__c = row.Issue_Key__c
        );
        if (row.Match_Status__c == REVIEW) {
            // Back in review (for example a new reason after an override): ask Claude again and let the
            // reviewer decide again. The overrides stay, so earlier choices are kept.
            result.AI_Status__c = null;
            result.AI_Confidence__c = null;
            result.AI_Suggestion__c = null;
            result.AI_Suggested_Firm__c = null;
            result.AI_Suggested_Fund__c = null;
            result.AI_Suggested_Advisor__c = null;
            result.AI_Request__c = null;
            result.AI_Headline__c = null;
            result.AI_Recommended_Action__c = null;
            result.AI_Homework__c = null;
            result.AI_Field_Suggestions__c = null;
            result.Reviewer_Decision__c = null;
            result.Decided_By__c = null;
            result.Decided_At__c = null;
        }
        return result;
    }

    /**
     * What rows with the same problem have in common, so one decision can settle all of them: the dealer, each firm
     * or fund issue and the spelling it is about (and the code, when the right answer can differ by code, as for a
     * missing or ambiguous name). Blank for rows that are not waiting for review, roster rows and code issues, which
     * are decided one by one. Long keys are hashed so they always fit and never collide.
     */
    @TestVisible
    private static String issueKey(String dealer, Import_Staging_Row__c row, Outcome o) {
        if (o.status != REVIEW || row.Row_Type__c == TradeRowNormalizer.ROW_ROSTER) {
            return null;
        }
        Set<String> flags = new Set<String>(o.flags);
        for (String f : CODE_FLAGS) {
            if (flags.contains(f)) {
                return null;
            }
        }
        List<String> parts = new List<String>{ (dealer == null ? '' : dealer.toUpperCase()) };
        for (String issue : SHARED_ISSUES) {
            if (!flags.contains(issue)) {
                continue;
            }
            Boolean firm = issue.startsWith('FIRM');
            String spelling = NameNormalizer.firmKey(firm ? row.Source_Firm_Name__c : row.Source_Fund_Name__c);
            String part = issue + '=' + (spelling == null ? '' : spelling);
            if (issue == 'FIRM_MISSING' || issue.endsWith('AMBIGUOUS')) {
                part += '@' + (row.Source_Rep_Code__c == null ? '' : row.Source_Rep_Code__c.trim().toUpperCase());
            }
            parts.add(part);
        }
        if (parts.size() == 1) {
            return null;
        }
        String key = String.join(parts, '|');
        return key.length() <= 255 ? key : 'H:' + EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(key)));
    }

    /**
     * The flags as stored in Match_Flags__c (255 characters). Whole flags are kept in order and any that do not fit
     * are dropped, so a flag is never cut in half (a half flag would silently change how the row is routed).
     */
    public static String joinFlags(List<String> flags) {
        List<String> kept = new List<String>();
        Integer length = 0;
        for (String f : flags) {
            Integer added = (kept.isEmpty() ? 0 : 1) + f.length();
            if (length + added > 255) {
                continue;
            }
            kept.add(f);
            length += added;
        }
        return kept.isEmpty() ? null : String.join(kept, ';');
    }

    private static void apply(Import_Staging_Row__c row, Outcome o) {
        row.Match_Status__c = o.status;
        row.Match_Method__c = o.status == MATCHED ? o.method : null;
        row.Matched_Firm__c = o.firmId;
        row.Matched_Rep_Code__c = o.repCodeId;
        row.Matched_Fund__c = o.fundId;
        row.Credited_Advisor__c = o.creditedAdvisorId;
        row.Match_Flags__c = joinFlags(o.flags);
        row.Match_Notes__c = o.notes.isEmpty() ? null : String.join(o.notes, '\n').abbreviate(5000);
        row.Match_Candidates__c = o.candidates.isEmpty() ? null : System.JSON.serialize(o.candidates).abbreviate(32768);
    }

    // ================================================================== reference data

    @TestVisible
    private class Resolution {
        public Id id;
        public Boolean fuzzy = false;
        public Boolean ambiguous = false;
        public List<Map<String, Object>> candidates = new List<Map<String, Object>>();
    }

    /** Everything matching needs, loaded with a fixed number of queries regardless of row count. */
    @TestVisible
    private with sharing class Reference {
        public Map<String, Set<Id>> firmIdsByKey = new Map<String, Set<Id>>();
        public Map<String, Set<Id>> fundIdsByKey = new Map<String, Set<Id>>();
        public List<String> firmAliasKeys = new List<String>();
        public List<String> fundAliasKeys = new List<String>();
        public Map<Id, String> firmNames = new Map<Id, String>();
        public Map<Id, String> fundNames = new Map<Id, String>();
        private Map<String, Rep_Code__c> codesByFirmAndValue = new Map<String, Rep_Code__c>();
        private Map<Id, List<Contact>> contactsByFirm = new Map<Id, List<Contact>>();
        private Map<String, Resolution> cache = new Map<String, Resolution>();

        public Reference(List<Import_Staging_Row__c> rows) {
            for (Firm_Alias__c fa : [
                SELECT Normalized_Key__c, Firm__c, Firm__r.Name
                FROM Firm_Alias__c
                WHERE Normalized_Key__c != NULL AND Firm__c != NULL
                WITH USER_MODE
                LIMIT 5000
            ]) {
                index(firmIdsByKey, firmAliasKeys, fa.Normalized_Key__c, fa.Firm__c);
                firmNames.put(fa.Firm__c, fa.Firm__r.Name);
            }
            for (Fund_Alias__c fa : [
                SELECT Normalized_Key__c, Fund__c, Fund__r.Name
                FROM Fund_Alias__c
                WHERE Normalized_Key__c != NULL AND Fund__c != NULL
                WITH USER_MODE
                LIMIT 5000
            ]) {
                index(fundIdsByKey, fundAliasKeys, fa.Normalized_Key__c, fa.Fund__c);
                fundNames.put(fa.Fund__c, fa.Fund__r.Name);
            }

            Set<Id> firmIds = new Set<Id>();
            Set<String> codes = new Set<String>();
            Boolean anyRoster = false;
            for (Import_Staging_Row__c row : rows) {
                if (row.Firm_Override__c != null) {
                    firmIds.add(row.Firm_Override__c);
                }
                String key = NameNormalizer.firmKey(row.Source_Firm_Name__c);
                if (key != null) {
                    Resolution r = resolve(key, firmIdsByKey, firmAliasKeys, firmNames);
                    if (r.id != null) {
                        firmIds.add(r.id);
                    }
                }
                if (row.Source_Rep_Code__c != null) {
                    codes.add(row.Source_Rep_Code__c);
                }
                anyRoster = anyRoster || row.Row_Type__c == TradeRowNormalizer.ROW_ROSTER;
            }
            for (Rep_Code__c rc : [
                SELECT
                    Id,
                    Name,
                    Firm__c,
                    (
                        SELECT
                            Id,
                            Advisor__c,
                            Advisor__r.FirstName,
                            Advisor__r.LastName,
                            Allocation_Percent__c,
                            Effective_Start_Date__c,
                            Effective_End_Date__c,
                            Last_Confirmed_Trade_Date__c
                        FROM Assignments__r
                    )
                FROM Rep_Code__c
                WHERE Firm__c IN :firmIds AND Name IN :codes
                WITH USER_MODE
            ]) {
                codesByFirmAndValue.put(rc.Firm__c + '|' + rc.Name.toUpperCase(), rc);
            }
            if (anyRoster && !firmIds.isEmpty()) {
                Map<Id, Id> firmOf = new Map<Id, Id>();
                for (Account a : [SELECT Id, ParentId FROM Account WHERE Id IN :firmIds OR ParentId IN :firmIds WITH USER_MODE]) {
                    firmOf.put(a.Id, firmIds.contains(a.Id) ? a.Id : a.ParentId);
                }
                for (Contact c : [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE AccountId IN :firmOf.keySet() WITH USER_MODE]) {
                    Id firm = firmOf.get(c.AccountId);
                    if (!contactsByFirm.containsKey(firm)) {
                        contactsByFirm.put(firm, new List<Contact>());
                    }
                    contactsByFirm.get(firm).add(c);
                }
            }
        }

        public Rep_Code__c code(Id firmId, String value) {
            return value == null ? null : codesByFirmAndValue.get(firmId + '|' + value.toUpperCase());
        }

        public List<Contact> contactsAtFirm(Id firmId) {
            return contactsByFirm.containsKey(firmId) ? contactsByFirm.get(firmId) : new List<Contact>();
        }

        /** Exact alias key first; otherwise the closest alias per record, accepted only if clearly the best. */
        public Resolution resolve(String key, Map<String, Set<Id>> idsByKey, List<String> aliasKeys, Map<Id, String> names) {
            String cacheKey = (idsByKey === firmIdsByKey ? 'firm|' : 'fund|') + key;
            if (cache.containsKey(cacheKey)) {
                return cache.get(cacheKey);
            }
            Resolution r = new Resolution();
            Set<Id> exact = idsByKey.get(key);
            if (exact != null && exact.size() == 1) {
                r.id = new List<Id>(exact)[0];
            } else if (exact != null) {
                r.ambiguous = true;
                for (Id candidate : exact) {
                    r.candidates.add(new Map<String, Object>{ 'id' => candidate, 'name' => names.get(candidate), 'score' => 1 });
                }
            } else {
                Map<Id, Decimal> best = new Map<Id, Decimal>();
                for (String aliasKey : aliasKeys) {
                    Decimal score = NameMatcher.similarity(key, aliasKey);
                    for (Id candidate : idsByKey.get(aliasKey)) {
                        if (!best.containsKey(candidate) || score > best.get(candidate)) {
                            best.put(candidate, score);
                        }
                    }
                }
                List<Scored> ranked = new List<Scored>();
                for (Id candidate : best.keySet()) {
                    ranked.add(new Scored(candidate, best.get(candidate)));
                }
                ranked.sort();
                if (!ranked.isEmpty() && ranked[0].score >= AUTO_ACCEPT && (ranked.size() == 1 || ranked[1].score <= ranked[0].score - MARGIN)) {
                    r.id = ranked[0].id;
                    r.fuzzy = true;
                } else {
                    for (Integer i = 0; i < ranked.size() && i < MAX_CANDIDATES; i++) {
                        r.candidates.add(new Map<String, Object>{ 'id' => ranked[i].id, 'name' => names.get(ranked[i].id), 'score' => ranked[i].score });
                    }
                }
            }
            cache.put(cacheKey, r);
            return r;
        }

        private void index(Map<String, Set<Id>> idsByKey, List<String> aliasKeys, String key, Id recordId) {
            if (!idsByKey.containsKey(key)) {
                idsByKey.put(key, new Set<Id>());
                aliasKeys.add(key);
            }
            idsByKey.get(key).add(recordId);
        }
    }

    /** Sorts by score descending, then by Id so results are stable. */
    private class Scored implements Comparable {
        public Id id;
        public Decimal score;

        public Scored(Id id, Decimal score) {
            this.id = id;
            this.score = score;
        }

        public Integer compareTo(Object other) {
            Scored that = (Scored) other;
            if (score != that.score) {
                return score > that.score ? -1 : 1;
            }
            return String.valueOf(id).compareTo(String.valueOf(that.id));
        }
    }
}
