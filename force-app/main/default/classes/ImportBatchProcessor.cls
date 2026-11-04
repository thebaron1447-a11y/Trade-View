/**
 * Reads the file attached to a Received Import_Batch__c, selects its mapping profile by header
 * fingerprint, and writes one Import_Staging_Row__c per data row.
 *
 * Outcomes: Staged (rows written, possibly with row-level validation errors; matching is then queued),
 * Mapping Review (no Active profile for this layout, or the profile is incomplete; with no profile at all,
 * Claude is asked to propose one, and activating a profile for this layout re-processes the batch),
 * Failed (the file could not be read or parsed; Error_Message__c says why).
 * All-or-nothing: on failure no staging rows are kept.
 *
 * Several files received together (a cloud pull) are read one after another in one job while limits allow, and the
 * rest in a follow-on job; the files that reach Staged are then matched together in one TradeMatcher job. An
 * asynchronous job may queue only one more, so the next step is queued once, at the end. If that fails (for example
 * the chain is too deep in a Developer Edition), the stranded work sweeper picks the files and rows up.
 */
public with sharing class ImportBatchProcessor implements Queueable {
    public class ImportException extends Exception {
    }

    public static final String STATUS_RECEIVED = 'Received';
    public static final String STATUS_PROCESSING = 'Processing';
    public static final String STATUS_MAPPING_REVIEW = 'Mapping Review';
    public static final String STATUS_STAGED = 'Staged';
    public static final String STATUS_FAILED = 'Failed';

    // Keeps heap well inside the 12 MB asynchronous limit. Larger files should be split by the sender.
    @TestVisible
    private static final Integer MAX_ROWS = 5000;

    private final List<Id> batchIds;
    // Files read to Staged by earlier jobs of the same chain, matched together at the end.
    private final Set<Id> staged;
    // Files that reached Mapping Review with no profile at all, for Claude to propose one.
    private final List<Id> needProposal = new List<Id>();

    public ImportBatchProcessor(Id batchId) {
        this(new List<Id>{ batchId }, new Set<Id>());
    }

    /** Several files received together, read in order. */
    public ImportBatchProcessor(List<Id> batchIds) {
        this(batchIds, new Set<Id>());
    }

    private ImportBatchProcessor(List<Id> batchIds, Set<Id> staged) {
        this.batchIds = batchIds;
        this.staged = staged;
    }

    public void execute(QueueableContext context) {
        List<Id> left = new List<Id>(batchIds);
        Boolean readOne = false;
        while (!left.isEmpty() && (!readOne || roomForAnother())) {
            readFile(left.remove(0));
            readOne = true;
        }
        queueNext(left);
    }

    /** The one job this one may queue: the rest of the files, else matching for the staged ones, else a proposal. */
    private void queueNext(List<Id> left) {
        if (Test.isRunningTest() || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        try {
            if (!left.isEmpty()) {
                System.enqueueJob(new ImportBatchProcessor(left, staged));
            } else if (!staged.isEmpty()) {
                System.enqueueJob(new TradeMatcher(staged));
            } else if (!needProposal.isEmpty() && AiSettings.get().enabled) {
                System.enqueueJob(new MappingProposalJob(needProposal[0]));
            }
        } catch (System.AsyncException e) {
            // Chain too deep: the sweeper restarts Received files and Pending rows within 15 minutes.
            return;
        }
    }

    /** Reading a file uses at most a third of each limit, so another fits when this much is left. */
    private static Boolean roomForAnother() {
        return Limits.getCpuTime() < Limits.getLimitCpuTime() / 3 &&
            Limits.getHeapSize() < Limits.getLimitHeapSize() / 3 &&
            Limits.getQueries() < Limits.getLimitQueries() / 2 &&
            Limits.getDmlStatements() < Limits.getLimitDmlStatements() / 2;
    }

    private void readFile(Id batchId) {
        // The batch is locked and moved to Processing before anything else, so a second job for the same batch
        // (a mapping activated twice, a manual re-queue) waits for this one and then finds it no longer Received.
        List<Import_Batch__c> batches = [
            SELECT Id, Status__c, Source_Firm__c
            FROM Import_Batch__c
            WHERE Id = :batchId
            WITH USER_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (batches.isEmpty() || batches[0].Status__c != STATUS_RECEIVED) {
            return;
        }
        Import_Batch__c batch = batches[0];
        SystemWriter.updateOne(new Import_Batch__c(Id = batch.Id, Status__c = STATUS_PROCESSING));
        batch.Status__c = STATUS_PROCESSING;
        Savepoint sp = Database.setSavepoint();
        try {
            process(batch);
        } catch (Exception e) {
            Database.rollback(sp);
            markFailed(batch.Id, e);
            batch.Status__c = STATUS_FAILED;
        }
        if (batch.Status__c == STATUS_STAGED) {
            staged.add(batch.Id);
        }
        TradeViewNotifier.changed(TradeViewNotifier.KIND_FILE, batch.Id);
        TradeViewNotifier.fileSettled(new Set<Id>{ batch.Id }, TradeViewNotifier.MOMENT_READ);
    }

    private void process(Import_Batch__c batch) {
        String text = loadFile(batch.Id);
        List<List<String>> rows = CsvParser.parse(text, CsvParser.detectDelimiter(text));
        if (rows.isEmpty()) {
            throw new ImportException('The file is empty.');
        }
        Integer dataRows = rows.size() - 1;
        if (dataRows == 0) {
            throw new ImportException('The file has a header row but no data rows.');
        }
        if (dataRows > MAX_ROWS) {
            throw new ImportException('The file has ' + dataRows + ' rows; the limit is ' + MAX_ROWS + '. Ask the sender to split it.');
        }
        List<String> headers = rows[0];
        batch.Row_Count__c = dataRows;

        Mapping_Profile__c profile;
        List<String> columns;
        String fingerprint = MappingService.fingerprint(headers);
        try {
            profile = MappingService.findActiveProfile(fingerprint, batch.Source_Firm__c);
            if (profile != null) {
                columns = MappingService.resolveColumns(headers, profile);
            }
        } catch (MappingService.MappingException e) {
            batch.Mapping_Profile__c = profile?.Id;
            batch.Header_Fingerprint__c = fingerprint;
            batch.Status__c = STATUS_MAPPING_REVIEW;
            batch.Error_Message__c = e.getMessage().abbreviate(5000);
            SystemWriter.updateOne(batch);
            return;
        }
        if (profile == null) {
            batch.Status__c = STATUS_MAPPING_REVIEW;
            batch.Header_Fingerprint__c = fingerprint;
            batch.Error_Message__c = 'No Active mapping profile matches this file layout. A mapping must be confirmed before the file can be read.';
            SystemWriter.updateOne(batch);
            needProposal.add(batch.Id);
            return;
        }

        TradeRowNormalizer.Config cfg = TradeRowNormalizer.configFrom(profile);
        List<Import_Staging_Row__c> staged = new List<Import_Staging_Row__c>();
        for (Integer r = 1; r < rows.size(); r++) {
            Import_Staging_Row__c row = TradeRowNormalizer.normalize(headers, rows[r], columns, cfg, r);
            row.Import_Batch__c = batch.Id;
            staged.add(row);
        }
        SystemWriter.insertAll(staged);

        batch.Mapping_Profile__c = profile.Id;
        batch.Status__c = STATUS_STAGED;
        batch.Error_Message__c = null;
        // Matching runs as its own job (queueNext) so each stage has full limits. Apex tests cannot chain queueable
        // jobs, so tests run TradeMatcher directly.
        SystemWriter.updateOne(batch);
    }

    /** The text of the file attached to the batch. Also used by MappingProposalJob to read sample rows. */
    public static String loadFile(Id batchId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :batchId
            WITH USER_MODE
            ORDER BY SystemModstamp DESC
            LIMIT 1
        ];
        if (links.isEmpty()) {
            throw new ImportException('No file is attached to this batch.');
        }
        Id versionId = links[0].ContentDocument.LatestPublishedVersionId;
        ContentVersion version = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1];
        try {
            return version.VersionData.toString();
        } catch (System.StringException e) {
            throw new ImportException('The file is not valid UTF-8 text. Ask the sender to export it as UTF-8.');
        }
    }

    private static void markFailed(Id batchId, Exception e) {
        Boolean expected = e instanceof ImportException || e instanceof CsvParser.CsvException;
        String message = expected ? e.getMessage() : e.getTypeName() + ': ' + e.getMessage();
        SystemWriter.updateOne(new Import_Batch__c(Id = batchId, Status__c = STATUS_FAILED, Error_Message__c = message.abbreviate(5000)));
    }
}
