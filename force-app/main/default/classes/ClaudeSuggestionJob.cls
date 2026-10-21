/**
 * Asks Claude for suggestions on rows in Needs Review and open Code Follow-Ups, a group at a time.
 * Queued by TradeMatcher after each matching run. Runs as a queueable because the Models API is a callout.
 *
 * Order matters: every callout in the job happens before any DML (Apex forbids a callout after uncommitted
 * work), then the logs and the AI fields are written. Each item is marked once (Suggested, No Suggestion,
 * Invalid or Failed), so items are never retried in a loop; clearing AI Status requests a new suggestion.
 * If more work remains, the job queues itself again.
 */
public with sharing class ClaudeSuggestionJob implements Queueable, Database.AllowsCallouts {
    @TestVisible
    private static final Integer MAX_REQUESTS_PER_JOB = 3;
    // Apex allows 120 seconds of callouts per transaction; stop starting new requests well before that.
    @TestVisible
    private static final Long TIME_BUDGET_MS = 60000;

    private final Set<Id> batchIds;

    /** batchIds limits the rows considered; null means all rows. Open follow-ups are always considered. */
    public ClaudeSuggestionJob(Set<Id> batchIds) {
        this.batchIds = batchIds;
    }

    public void execute(QueueableContext context) {
        Boolean moreWork = run(batchIds);
        if (moreWork && !Test.isRunningTest()) {
            try {
                System.enqueueJob(new ClaudeSuggestionJob(batchIds));
            } catch (System.AsyncException e) {
                // Chain depth reached (Developer Edition allows 5). Nothing is lost: remaining items keep a blank
                // AI Status and are picked up by the next matching run or by scripts/apex/request-suggestions.apex.
                return;
            }
        }
    }

    /** Processes up to MAX_REQUESTS_PER_JOB requests. Returns true if items are left for another run. */
    public static Boolean run(Set<Id> batchIds) {
        AiSettings settings = AiSettings.get();
        if (!settings.enabled) {
            return false;
        }
        Integer perRequest = settings.maxItemsPerRequest;
        Integer capacity = perRequest * MAX_REQUESTS_PER_JOB;
        // One extra of each tells us whether more work remains after this run.
        List<Import_Staging_Row__c> rows = ClaudeSuggestionService.pendingRows(batchIds, capacity + 1);
        List<Code_Follow_Up__c> followUps = ClaudeSuggestionService.pendingFollowUps(capacity + 1);
        if (rows.isEmpty() && followUps.isEmpty()) {
            return false;
        }

        List<Call> calls = new List<Call>();
        Long started = System.currentTimeMillis();
        Integer rowIndex = 0;
        Integer followUpIndex = 0;
        while (calls.size() < MAX_REQUESTS_PER_JOB && System.currentTimeMillis() - started < TIME_BUDGET_MS) {
            List<Import_Staging_Row__c> rowGroup = new List<Import_Staging_Row__c>();
            List<Code_Follow_Up__c> followUpGroup = new List<Code_Follow_Up__c>();
            while (rowGroup.size() + followUpGroup.size() < perRequest && rowIndex < rows.size() && rowIndex < capacity) {
                rowGroup.add(rows[rowIndex++]);
            }
            while (rowGroup.size() + followUpGroup.size() < perRequest && followUpIndex < followUps.size() && followUpIndex < capacity) {
                followUpGroup.add(followUps[followUpIndex++]);
            }
            if (rowGroup.isEmpty() && followUpGroup.isEmpty()) {
                break;
            }
            calls.add(ask(rowGroup, followUpGroup));
        }

        // All callouts are done; now write.
        List<AI_Request_Log__c> logs = new List<AI_Request_Log__c>();
        for (Call c : calls) {
            logs.add(c.result.log);
        }
        insert as user logs;
        List<Import_Staging_Row__c> rowUpdates = new List<Import_Staging_Row__c>();
        List<Code_Follow_Up__c> followUpUpdates = new List<Code_Follow_Up__c>();
        for (Call c : calls) {
            for (SObject u : ClaudeSuggestionService.updatesFor(c.request, c.result, c.validation, c.result.log.Id)) {
                if (u instanceof Import_Staging_Row__c) {
                    rowUpdates.add((Import_Staging_Row__c) u);
                } else {
                    followUpUpdates.add((Code_Follow_Up__c) u);
                }
            }
        }
        update as user rowUpdates;
        update as user followUpUpdates;
        return rowIndex < rows.size() || followUpIndex < followUps.size();
    }

    private class Call {
        public ClaudeSuggestionService.SuggestionRequest request;
        public ClaudeService.Result result;
        public ClaudeSuggestionService.Validation validation;
    }

    private static Call ask(List<Import_Staging_Row__c> rows, List<Code_Follow_Up__c> followUps) {
        Call c = new Call();
        c.request = ClaudeSuggestionService.buildRequest(rows, followUps);
        Id batchId = batchOf(rows);
        c.result = ClaudeService.call(ClaudeSuggestionService.PURPOSE, c.request.prompt, batchId, c.request.items.size());
        if (!c.result.ok) {
            return c;
        }
        try {
            c.validation = ClaudeSuggestionService.validate(ClaudeService.parseObject(c.result.text), c.request.items);
        } catch (ClaudeService.ClaudeException e) {
            c.result.reject(new List<String>{ e.getMessage() });
            return c;
        }
        if (!c.validation.usable) {
            c.result.reject(c.validation.problems);
        } else {
            c.result.note(c.validation.problems);
        }
        return c;
    }

    /** The batch, when every row in the request comes from the same one. */
    private static Id batchOf(List<Import_Staging_Row__c> rows) {
        Set<Id> ids = new Set<Id>();
        for (Import_Staging_Row__c r : rows) {
            ids.add(r.Import_Batch__c);
        }
        return ids.size() == 1 ? new List<Id>(ids)[0] : null;
    }
}
