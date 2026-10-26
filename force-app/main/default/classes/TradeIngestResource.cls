/**
 * Inbound endpoint for the data lake push job. Validates the request and hands the file to FileIntakeService,
 * the same intake the review app's upload uses.
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

    @HttpPost
    global static void ingest() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> body = parseBody(RestContext.request.requestBody);
            String sourceFirm = requiredString(body, 'sourceFirm', 80);
            String fileName = requiredString(body, 'fileName', FileIntakeService.MAX_FILE_NAME);
            Blob file = decode(requiredString(body, 'content', null));
            Object clientHash = body.get('fileHash');
            FileIntakeService.Receipt r = FileIntakeService.receive(sourceFirm, fileName, file, clientHash == null ? null : String.valueOf(clientHash));
            if (r.hidden) {
                error(res, 409, r.message);
                return;
            }
            respond(res, r.duplicate ? 200 : 201, r);
        } catch (RequestException e) {
            Database.rollback(sp);
            error(res, 400, e.getMessage());
        } catch (FileIntakeService.IntakeException e) {
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

    private static void respond(RestResponse res, Integer code, FileIntakeService.Receipt r) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(
            System.JSON.serialize(
                new Map<String, Object>{ 'batchId' => r.batchId, 'status' => r.status, 'duplicate' => r.duplicate, 'message' => r.message }
            )
        );
    }

    private static void error(RestResponse res, Integer code, String message) {
        res.statusCode = code;
        res.responseBody = Blob.valueOf(System.JSON.serialize(new Map<String, Object>{ 'error' => message }));
    }
}
