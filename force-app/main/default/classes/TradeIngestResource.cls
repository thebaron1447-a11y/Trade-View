/**
 * Inbound endpoint for the data lake push job.
 *
 * POST /services/apexrest/trade-import/v1/files
 * Body (JSON): { "sourceFirm": "BARDER", "fileName": "trades.csv", "content": "<base64>", "fileHash": "<sha256 hex, optional>" }
 *
 * 201 new batch created and queued; 200 the same file was already received (no new batch);
 * 400 invalid request; 409 already received but not visible to this user; 500 unexpected error.
 */
@RestResource(urlMapping='/trade-import/v1/files')
global with sharing class TradeIngestResource {
    @TestVisible
    private class RequestException extends Exception {
    }

    // The request body, its JSON parse and the decoded file all sit in the 6 MB synchronous heap at once.
    // 1 MB of CSV is roughly 5,000+ trade rows, which matches ImportBatchProcessor.MAX_ROWS.
    @TestVisible
    private static Integer maxFileBytes = 1024 * 1024;
    private static final Pattern FIRM_CODE = Pattern.compile('^[A-Za-z0-9_-]{1,80}$');

    @HttpPost
    global static void ingest() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> body = parseBody(RestContext.request.requestBody);
            String sourceFirm = requiredString(body, 'sourceFirm', 80).toUpperCase();
            if (!FIRM_CODE.matcher(sourceFirm).matches()) {
                throw new RequestException('sourceFirm may contain only letters, digits, hyphens and underscores.');
            }
            String fileName = requiredString(body, 'fileName', 255);
            Blob file = decode(requiredString(body, 'content', null));
            String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', file));
            Object clientHash = body.get('fileHash');
            if (clientHash != null && !hash.equalsIgnoreCase(String.valueOf(clientHash))) {
                throw new RequestException('fileHash does not match the file contents. The file may have been corrupted in transit.');
            }

            Import_Batch__c existing = findByHash(hash);
            if (existing != null) {
                respond(res, 200, existing, true, 'This file was already received.');
                return;
            }
            Import_Batch__c batch = new Import_Batch__c(
                Source_Firm__c = sourceFirm,
                Source_File_Name__c = fileName,
                File_Hash__c = hash,
                Status__c = ImportBatchProcessor.STATUS_RECEIVED
            );
            try {
                insert as user batch;
            } catch (DmlException e) {
                // Another request inserted the same file between our check and our insert.
                if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                    Database.rollback(sp);
                    duplicateResponse(res, findByHash(hash));
                    return;
                }
                throw e;
            }
            insert as user new ContentVersion(Title = fileName, PathOnClient = fileName, VersionData = file, FirstPublishLocationId = batch.Id);
            System.enqueueJob(new ImportBatchProcessor(batch.Id));
            respond(res, 201, batch, false, 'File received and queued for processing.');
        } catch (RequestException e) {
            Database.rollback(sp);
            error(res, 400, e.getMessage());
        } catch (Exception e) {
            Database.rollback(sp);
            error(res, 500, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    private static Map<String, Object> parseBody(Blob requestBody) {
        if (requestBody == null || requestBody.size() == 0) {
            throw new RequestException('Request body is empty.');
        }
        Object parsed;
        try {
            parsed = System.JSON.deserializeUntyped(requestBody.toString());
        } catch (Exception e) {
            throw new RequestException('Request body must be valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new RequestException('Request body must be a JSON object.');
        }
        return (Map<String, Object>) parsed;
    }

    private static String requiredString(Map<String, Object> body, String key, Integer maxLength) {
        Object value = body.get(key);
        if (value == null || !(value instanceof String) || String.isBlank((String) value)) {
            throw new RequestException(key + ' is required.');
        }
        String s = ((String) value).trim();
        if (maxLength != null && s.length() > maxLength) {
            throw new RequestException(key + ' must be ' + maxLength + ' characters or fewer.');
        }
        return s;
    }

    private static Blob decode(String base64) {
        // Base64 is 4/3 the size of the file; reject before decoding to protect the heap.
        if (base64.length() > (maxFileBytes / 3 + 1) * 4) {
            throw new RequestException('The file is larger than ' + (maxFileBytes / 1024) + ' KB. Ask the sender to split it.');
        }
        Blob file;
        try {
            file = EncodingUtil.base64Decode(base64);
        } catch (Exception e) {
            throw new RequestException('content must be base64-encoded.');
        }
        if (file == null || file.size() == 0) {
            throw new RequestException('The file is empty.');
        }
        return file;
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

    private static void duplicateResponse(RestResponse res, Import_Batch__c existing) {
        if (existing == null) {
            error(res, 409, 'This file was already received, but the batch is not visible to this user.');
        } else {
            respond(res, 200, existing, true, 'This file was already received.');
        }
    }

    private static void respond(RestResponse res, Integer code, Import_Batch__c batch, Boolean duplicate, String message) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(
            System.JSON.serialize(
                new Map<String, Object>{
                    'batchId' => batch.Id,
                    'status' => batch.Status__c,
                    'duplicate' => duplicate,
                    'message' => message
                }
            )
        );
    }

    private static void error(RestResponse res, Integer code, String message) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(System.JSON.serialize(new Map<String, Object>{ 'error' => message }));
    }
}
