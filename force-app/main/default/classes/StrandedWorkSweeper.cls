/**
 * Restarts work left stranded between background steps (audit F-08). Each step queues the next one only when the
 * transaction still has a queueable slot, and Developer Edition limits how deep a chain of jobs can go, so a step can
 * end without starting the next: files stay Received, rows stay Pending, items are never sent to Claude. Nothing else
 * picks them up, and the app's in-flight counter keeps waiting.
 *
 * Scheduled every 15 minutes (scheduleEvery15Minutes). Each run restarts, at most once:
 *   - files Received but never staged (ImportBatchProcessor, one job per file);
 *   - rows Pending in a staged file (TradeMatcher, one job for those files);
 *   - rows and code reviews Claude was never asked about, when Claude is on (ClaudeSuggestionJob);
 *   - files left Loading part way (TradeLoader, one job per file).
 * It also starts the cloud pulls that are due (CloudPullJob, one job per source; phase 4c), so the 15-minute rhythm
 * that keeps work moving is the one clock for scheduled pulls too.
 * Only work untouched for QUIET_MINUTES is taken, and a kind of work is skipped while a job of that kind is queued or
 * running, so the sweeper never races a job that is about to finish. Work that failed is never retried: a failure
 * marks the item (Failed status), so nothing loops.
 */
public with sharing class StrandedWorkSweeper implements Schedulable {
    public static final String JOB_NAME = 'Trade View stranded work sweeper';
    public static final Integer QUIET_MINUTES = 10;
    @TestVisible
    private static Integer quietMinutes = QUIET_MINUTES;
    @TestVisible
    private static final Integer MAX_FILES = 20;
    private static final List<String> STAGES = new List<String>{ ':00', ':15', ':30', ':45' };

    /** What one run restarted. */
    public class Result {
        public Integer filesRestarted = 0;
        public Integer batchesRematched = 0;
        public Boolean claudeRestarted = false;
        public Integer loadsRestarted = 0;
        public Integer pullsStarted = 0;
    }

    public void execute(SchedulableContext context) {
        sweep();
    }

    // ImportBatchProcessor takes one file, so stranded files are queued one job each: at most MAX_FILES, and only
    // while a queueable slot is left.
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    public static Result sweep() {
        Result result = new Result();
        Datetime quietSince = System.now().addMinutes(-quietMinutes);
        Set<String> busy = busyJobs();

        if (!busy.contains('ImportBatchProcessor')) {
            for (Import_Batch__c b : [
                SELECT Id
                FROM Import_Batch__c
                WHERE Status__c = :ImportBatchProcessor.STATUS_RECEIVED AND LastModifiedDate < :quietSince
                WITH USER_MODE
                ORDER BY CreatedDate
                LIMIT :MAX_FILES
            ]) {
                if (!canQueue()) {
                    break;
                }
                System.enqueueJob(new ImportBatchProcessor(b.Id));
                result.filesRestarted++;
            }
        }

        if (!busy.contains('TradeMatcher') && canQueue()) {
            // The statuses TradeMatcher.run accepts.
            Set<String> ready = new Set<String>{ ImportBatchProcessor.STATUS_STAGED, TradeMatcher.STATUS_PENDING_REVIEW };
            Set<Id> batchIds = new Set<Id>();
            for (AggregateResult ar : [
                SELECT Import_Batch__c batchId
                FROM Import_Staging_Row__c
                WHERE Match_Status__c = :TradeMatcher.PENDING AND LastModifiedDate < :quietSince AND Import_Batch__r.Status__c IN :ready
                WITH USER_MODE
                GROUP BY Import_Batch__c
                LIMIT :MAX_FILES
            ]) {
                batchIds.add((Id) ar.get('batchId'));
            }
            if (!batchIds.isEmpty()) {
                System.enqueueJob(new TradeMatcher(batchIds));
                result.batchesRematched = batchIds.size();
            }
        }

        if (AiSettings.get().enabled && !busy.contains('ClaudeSuggestionJob') && waitingForClaude(quietSince) && canQueue()) {
            System.enqueueJob(new ClaudeSuggestionJob(null));
            result.claudeRestarted = true;
        }

        if (!busy.contains('TradeLoader')) {
            for (Import_Batch__c b : [
                SELECT Id
                FROM Import_Batch__c
                WHERE Status__c = :TradeLoader.STATUS_LOADING AND LastModifiedDate < :quietSince
                WITH USER_MODE
                ORDER BY CreatedDate
                LIMIT :MAX_FILES
            ]) {
                if (!canQueue()) {
                    break;
                }
                System.enqueueJob(new TradeLoader(b.Id));
                result.loadsRestarted++;
            }
        }

        if (!busy.contains('CloudPullJob')) {
            List<Cloud_Source__c> starting = new List<Cloud_Source__c>();
            for (Cloud_Source__c src : CloudPullService.dueSources(System.now(), MAX_FILES)) {
                if (!canQueue()) {
                    break;
                }
                System.enqueueJob(new CloudPullJob(src.Id));
                starting.add(new Cloud_Source__c(Id = src.Id, Last_Pull_Status__c = CloudPullService.PULLING));
                result.pullsStarted++;
            }
            SystemWriter.updateAll(starting);
        }
        return result;
    }

    /** Schedules the sweeper at :00, :15, :30 and :45 past every hour, replacing any earlier schedule. Returns the job Ids. */
    // A cron expression can name one minute of the hour, so a 15-minute rhythm takes four schedules.
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    public static List<Id> scheduleEvery15Minutes() {
        unschedule();
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < STAGES.size(); i++) {
            ids.add(System.schedule(JOB_NAME + ' ' + STAGES[i], '0 ' + (i * 15) + ' * * * ?', new StrandedWorkSweeper()));
        }
        return ids;
    }

    /** Removes every sweeper schedule. */
    public static void unschedule() {
        String pattern = JOB_NAME + '%';
        // Job tables are setup data, read in system mode by whoever schedules the sweeper (an admin).
        for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :pattern WITH SYSTEM_MODE]) {
            System.abortJob(t.Id);
        }
    }

    /** The kinds of job queued or running right now. */
    private static Set<String> busyJobs() {
        Set<String> result = new Set<String>();
        for (AsyncApexJob j : [
            SELECT ApexClass.Name
            FROM AsyncApexJob
            WHERE
                JobType = 'Queueable'
                AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
                AND ApexClass.Name IN ('ImportBatchProcessor', 'TradeMatcher', 'ClaudeSuggestionJob', 'TradeLoader', 'CloudPullJob')
            WITH SYSTEM_MODE
        ]) {
            result.add(j.ApexClass.Name);
        }
        return result;
    }

    private static Boolean waitingForClaude(Datetime quietSince) {
        return [
                SELECT COUNT()
                FROM Import_Staging_Row__c
                WHERE Match_Status__c = :TradeMatcher.REVIEW AND AI_Status__c = NULL AND Reviewer_Decision__c = NULL AND LastModifiedDate < :quietSince
                WITH USER_MODE
            ] > 0 ||
            [
                SELECT COUNT()
                FROM Code_Follow_Up__c
                WHERE Status__c IN ('Open', 'In Progress') AND AI_Status__c = NULL AND LastModifiedDate < :quietSince
                WITH USER_MODE
            ] > 0;
    }

    private static Boolean canQueue() {
        return Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
    }
}
