@IsTest
private class TradeIngestResourceTest {
    private static final String CSV = 'Representative,Rep No.,Value\r\nRyan Chen,1001,100\r\n';

    private static Map<String, Object> post(Map<String, Object> body) {
        return postRaw(body == null ? null : Blob.valueOf(System.JSON.serialize(body)));
    }

    private static Map<String, Object> postRaw(Blob body) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/trade-import/v1/files';
        req.httpMethod = 'POST';
        req.requestBody = body;
        RestContext.request = req;
        RestContext.response = new RestResponse();
        TradeIngestResource.ingest();
        Map<String, Object> result = (Map<String, Object>) System.JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        result.put('httpStatus', RestContext.response.statusCode);
        return result;
    }

    private static Map<String, Object> body(String content) {
        return new Map<String, Object>{
            'sourceFirm' => 'kestrel',
            'fileName' => 'kestrel_2026-10-01.csv',
            'content' => EncodingUtil.base64Encode(Blob.valueOf(content))
        };
    }

    @IsTest
    static void createsBatchAttachesFileAndQueuesProcessing() {
        User integration = TestDataFactory.integrationUser();
        Map<String, Object> result;
        System.runAs(integration) {
            Test.startTest();
            result = post(body(CSV));
            Test.stopTest();
        }
        Assert.areEqual(201, result.get('httpStatus'), 'detail: ' + result);
        Assert.areEqual(false, result.get('duplicate'), 'new file');
        Id batchId = (Id) result.get('batchId');
        Import_Batch__c batch = [SELECT Source_Firm__c, Source_File_Name__c, File_Hash__c, Status__c FROM Import_Batch__c WHERE Id = :batchId];
        Assert.areEqual('KESTREL', batch.Source_Firm__c, 'firm code upper-cased');
        Assert.areEqual(EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(CSV))), batch.File_Hash__c, 'server-side hash');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :batchId], 'file attached');
        Assert.areEqual(ImportBatchProcessor.STATUS_MAPPING_REVIEW, batch.Status__c, 'queued job ran; no profile exists for this layout');
    }

    @IsTest
    static void sameFileTwiceReturnsExistingBatch() {
        User integration = TestDataFactory.integrationUser();
        Map<String, Object> first;
        Map<String, Object> second;
        System.runAs(integration) {
            Test.startTest();
            first = post(body(CSV));
            second = post(body(CSV));
            Test.stopTest();
        }
        Assert.areEqual(201, first.get('httpStatus'), 'first');
        Assert.areEqual(200, second.get('httpStatus'), 'second');
        Assert.areEqual(true, second.get('duplicate'), 'duplicate flagged');
        Assert.areEqual(first.get('batchId'), second.get('batchId'), 'same batch');
        Assert.areEqual(1, [SELECT COUNT() FROM Import_Batch__c], 'no second batch');
    }

    @IsTest
    static void acceptsMatchingClientHashAndRejectsMismatch() {
        Map<String, Object> good = body(CSV);
        good.put('fileHash', EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(CSV))).toUpperCase());
        Map<String, Object> bad = body(CSV + 'x');
        bad.put('fileHash', good.get('fileHash'));
        Test.startTest();
        Map<String, Object> ok = post(good);
        Map<String, Object> rejected = post(bad);
        Test.stopTest();
        Assert.areEqual(201, ok.get('httpStatus'), 'hash comparison is case-insensitive');
        Assert.areEqual(400, rejected.get('httpStatus'), 'mismatch rejected');
        Assert.isTrue(String.valueOf(rejected.get('error')).contains('does not match'), 'detail: ' + rejected);
        Assert.areEqual(1, [SELECT COUNT() FROM Import_Batch__c], 'rejected request created nothing');
    }

    @IsTest
    static void rejectsInvalidRequests() {
        Map<String, Object> missingFirm = body(CSV);
        missingFirm.remove('sourceFirm');
        Map<String, Object> badFirm = body(CSV);
        badFirm.put('sourceFirm', 'Barder & Co');
        Map<String, Object> longName = body(CSV);
        longName.put('fileName', 'x'.repeat(256));
        Map<String, Object> numberContent = body(CSV);
        numberContent.put('content', 42);

        List<List<Object>> cases = new List<List<Object>>{
            new List<Object>{ post(missingFirm), 'sourceFirm is required' },
            new List<Object>{ post(badFirm), 'only letters' },
            new List<Object>{ post(longName), '255 characters' },
            new List<Object>{ post(numberContent), 'content is required' },
            new List<Object>{ postRaw(Blob.valueOf('{oops')), 'valid JSON' },
            new List<Object>{ postRaw(Blob.valueOf('[1]')), 'JSON object' },
            new List<Object>{ postRaw(null), 'empty' }
        };
        for (List<Object> c : cases) {
            Map<String, Object> result = (Map<String, Object>) c[0];
            String expected = (String) c[1];
            Assert.areEqual(400, result.get('httpStatus'), expected + ': ' + result);
            Assert.isTrue(String.valueOf(result.get('error')).contains(expected), result + ' should contain ' + expected);
        }
        Assert.areEqual(400, RestContext.response.statusCode, 'last response is a 400');
        Assert.areEqual(0, [SELECT COUNT() FROM Import_Batch__c], 'nothing created');
    }

    @IsTest
    static void rejectsOversizedFileBeforeDecoding() {
        TradeIngestResource.maxFileBytes = 30;
        Map<String, Object> result = post(body(CSV));
        Assert.areEqual(400, result.get('httpStatus'), 'too large');
        Assert.isTrue(String.valueOf(result.get('error')).contains('larger than'), 'detail: ' + result);
    }
}
