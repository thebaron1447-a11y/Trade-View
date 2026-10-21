/**
 * Reads the file attached to a Received Import_Batch__c, selects its mapping profile by header
 * fingerprint, and writes one Import_Staging_Row__c per data row.
 *
 * Outcomes: Staged (rows written, possibly with row-level validation errors; matching is then queued),
 * Mapping Review (no Active profile for this layout, or the profile is incomplete; with no profile at all,
 * Claude is asked to propose one, and activating a profile for this layout re-processes the batch),
 * Failed (the file could not be read or parsed; Error_Message__c says why).
 * All-or-nothing: on failure no staging rows are kept.
 */
public with sharing class ImportBatchProcessor implements Queueable {
    public class ImportException extends Exception {
    }

    public static final String STATUS_RECEIVED = 'Received';
    public static final String STATUS_MAPPING_REVIEW = 'Mapping Review';
    public static final String STATUS_STAGED = 'Staged';
    public static final String STATUS_FAILED = 'Failed';

    // Keeps heap well inside the 12 MB asynchronous limit. Larger files should be split by the sender.
    @TestVisible
    private static final Integer MAX_ROWS = 5000;

    private final Id batchId;

    public ImportBatchProcessor(Id batchId) {
        this.batchId = batchId;
    }

    public void execute(QueueableContext context) {
        List<Import_Batch__c> batches = [
            SELECT Id, Status__c, Source_Firm__c
            FROM Import_Batch__c
            WHERE Id = :batchId
            WITH USER_MODE
            LIMIT 1
        ];
        // Only Received batches are processed, so a re-queued job can never stage a file twice.
        if (batches.isEmpty() || batches[0].Status__c != STATUS_RECEIVED) {
            return;
        }
        Import_Batch__c batch = batches[0];
        Savepoint sp = Database.setSavepoint();
        try {
            process(batch);
        } catch (Exception e) {
            Database.rollback(sp);
            markFailed(batch.Id, e);
        }
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
            update as user batch;
            return;
        }
        if (profile == null) {
            batch.Status__c = STATUS_MAPPING_REVIEW;
            batch.Header_Fingerprint__c = fingerprint;
            batch.Error_Message__c = 'No Active mapping profile matches this file layout. A mapping must be confirmed before the file can be read.';
            update as user batch;
            if (AiSettings.get().enabled && !Test.isRunningTest()) {
                System.enqueueJob(new MappingProposalJob(batch.Id));
            }
            return;
        }

        TradeRowNormalizer.Config cfg = TradeRowNormalizer.configFrom(profile);
        List<Import_Staging_Row__c> staged = new List<Import_Staging_Row__c>();
        for (Integer r = 1; r < rows.size(); r++) {
            Import_Staging_Row__c row = TradeRowNormalizer.normalize(headers, rows[r], columns, cfg, r);
            row.Import_Batch__c = batch.Id;
            staged.add(row);
        }
        insert as user staged;

        batch.Mapping_Profile__c = profile.Id;
        batch.Status__c = STATUS_STAGED;
        batch.Error_Message__c = null;
        update as user batch;
        // Matching runs as its own job so each stage has full limits. Apex tests cannot chain queueable
        // jobs, so tests run TradeMatcher directly.
        if (!Test.isRunningTest()) {
            System.enqueueJob(new TradeMatcher(new Set<Id>{ batch.Id }));
        }
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
        update as user new Import_Batch__c(Id = batchId, Status__c = STATUS_FAILED, Error_Message__c = message.abbreviate(5000));
    }
}
