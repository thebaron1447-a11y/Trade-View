/**
 * Receives one dealer file, whichever way it arrives (the data lake push job, an upload in the review app, or a
 * cloud storage pull), and starts the same pipeline: a Received Import_Batch__c with the file attached, then
 * ImportBatchProcessor. The same file twice (by SHA-256 of its contents) returns the existing batch instead of
 * creating a second one.
 */
public with sharing class FileIntakeService {
    public class IntakeException extends Exception {
    }

    // The decoded file, its text and the parsed rows sit in the heap together; 1 MB is about 5,000 trade rows,
    // which matches ImportBatchProcessor.MAX_ROWS.
    public static final Integer MAX_FILE_BYTES = 1024 * 1024;
    public static final Integer MAX_FILE_NAME = 255;
    private static final Pattern FIRM_CODE = Pattern.compile('^[A-Za-z0-9_-]{1,80}$');

    public class Receipt {
        @AuraEnabled
        public Id batchId;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Boolean duplicate = false;
        /** The same file was received before, but its batch is not visible to this user. */
        @AuraEnabled
        public Boolean hidden = false;
        @AuraEnabled
        public String message;
    }

    /** The source firm code in its stored form (upper case), or an IntakeException explaining what is allowed. */
    public static String sourceFirmCode(String value) {
        String code = value == null ? '' : value.trim().toUpperCase();
        if (!FIRM_CODE.matcher(code).matches()) {
            throw new IntakeException('Source firm codes may contain only letters, digits, hyphens and underscores (up to 80).');
        }
        return code;
    }

    /**
     * Creates a Received batch with the file attached and queues processing.
     * expectedHash, when given, must match the file's SHA-256 (hex, any case): it proves the file was not
     * corrupted in transit.
     */
    public static Receipt receive(String sourceFirm, String fileName, Blob file, String expectedHash) {
        String firm = sourceFirmCode(sourceFirm);
        String name = fileName == null ? '' : fileName.trim();
        if (name.length() == 0) {
            throw new IntakeException('A file name is required.');
        }
        if (name.length() > MAX_FILE_NAME) {
            throw new IntakeException('The file name must be ' + MAX_FILE_NAME + ' characters or fewer.');
        }
        if (file == null || file.size() == 0) {
            throw new IntakeException('The file is empty.');
        }
        if (file.size() > MAX_FILE_BYTES) {
            throw new IntakeException('The file is larger than ' + (MAX_FILE_BYTES / 1024) + ' KB. Ask the sender to split it.');
        }
        String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', file));
        if (expectedHash != null && !hash.equalsIgnoreCase(expectedHash)) {
            throw new IntakeException('fileHash does not match the file contents. The file may have been corrupted in transit.');
        }

        Import_Batch__c existing = findByHash(hash);
        if (existing != null) {
            return receipt(existing, true);
        }
        Import_Batch__c batch = new Import_Batch__c(
            Source_Firm__c = firm,
            Source_File_Name__c = name,
            File_Hash__c = hash,
            Status__c = ImportBatchProcessor.STATUS_RECEIVED
        );
        Savepoint sp = Database.setSavepoint();
        try {
            insert as user batch;
        } catch (DmlException e) {
            // Another request inserted the same file between the check above and this insert.
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                Database.rollback(sp);
                Import_Batch__c other = findByHash(hash);
                if (other != null) {
                    return receipt(other, true);
                }
                Receipt hidden = new Receipt();
                hidden.duplicate = true;
                hidden.hidden = true;
                hidden.message = 'This file was already received, but the batch is not visible to this user.';
                return hidden;
            }
            throw e;
        }
        insert as user new ContentVersion(Title = name, PathOnClient = name, VersionData = file, FirstPublishLocationId = batch.Id);
        System.enqueueJob(new ImportBatchProcessor(batch.Id));
        return receipt(batch, false);
    }

    private static Import_Batch__c findByHash(String hash) {
        List<Import_Batch__c> found = [
            SELECT Id, Status__c
            FROM Import_Batch__c
            WHERE File_Hash__c = :hash
            WITH USER_MODE
            LIMIT 1
        ];
        return found.isEmpty() ? null : found[0];
    }

    private static Receipt receipt(Import_Batch__c batch, Boolean duplicate) {
        Receipt r = new Receipt();
        r.batchId = batch.Id;
        r.status = batch.Status__c;
        r.duplicate = duplicate;
        r.message = duplicate ? 'This file was already received.' : 'File received and queued for processing.';
        return r;
    }
}
