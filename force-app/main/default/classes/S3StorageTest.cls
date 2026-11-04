@IsTest
private class S3StorageTest {
    private static final String NS = 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/"';

    /** Answers each request with the next canned response, and remembers what was asked. */
    private class S3Mock implements HttpCalloutMock {
        public List<HttpResponse> responses = new List<HttpResponse>();
        public List<String> endpoints = new List<String>();

        public HttpResponse respond(HttpRequest req) {
            endpoints.add(req.getEndpoint());
            Assert.areEqual('GET', req.getMethod(), 'S3 is only ever read');
            return responses.remove(0);
        }
    }

    private static HttpResponse reply(Integer status, String body) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(status);
        res.setBody(body);
        return res;
    }

    private static Cloud_Source__c source() {
        return new Cloud_Source__c(Named_Credential__c = 'Trade_View_S3', Folder__c = 'inbox/', Provider__c = 'Amazon S3');
    }

    @IsTest
    static void listsTheFolderAcrossPages() {
        S3Mock mock = new S3Mock();
        mock.responses.add(
            reply(
                200,
                '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult ' +
                    NS +
                    '><IsTruncated>true</IsTruncated><NextContinuationToken>next token</NextContinuationToken>' +
                    '<Contents><Key>inbox/BARDER/barder_trades.csv</Key><ETag>"abc123"</ETag><Size>2048</Size></Contents>' +
                    '<Contents><Key>inbox/</Key><ETag>"d41d8"</ETag><Size>0</Size></Contents></ListBucketResult>'
            )
        );
        mock.responses.add(
            reply(
                200,
                '<ListBucketResult ' +
                    NS +
                    '><IsTruncated>false</IsTruncated>' +
                    '<Contents><Key>inbox/KESTREL/export.csv</Key><ETag>"def456"</ETag><Size>99</Size></Contents></ListBucketResult>'
            )
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<CloudPullService.CloudObject> files = new S3Storage().listFiles(source());
        Test.stopTest();

        Assert.areEqual(3, files.size(), 'both pages, folder marker included (the pull skips it)');
        Assert.areEqual('inbox/BARDER/barder_trades.csv', files[0].key, 'path');
        Assert.areEqual('abc123', files[0].etag, 'version tag without quotes');
        Assert.areEqual(2048L, files[0].size, 'size');
        Assert.areEqual('inbox/KESTREL/export.csv', files[2].key, 'second page');
        Assert.areEqual('callout:Trade_View_S3/?list-type=2&max-keys=1000&prefix=inbox%2F', mock.endpoints[0], 'first page');
        Assert.isTrue(mock.endpoints[1].endsWith('&continuation-token=next%20token'), 'continues where it left off: ' + mock.endpoints[1]);
    }

    @IsTest
    static void readsAFileByItsPath() {
        S3Mock mock = new S3Mock();
        mock.responses.add(reply(200, 'Representative,Rep No.\nRyan Chen,1001\n'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Blob file = new S3Storage().readFile(source(), 'inbox/BARDER/trades 2026~10.csv');
        Test.stopTest();

        Assert.isTrue(file.toString().startsWith('Representative'), 'the file');
        Assert.areEqual('callout:Trade_View_S3/inbox/BARDER/trades%202026~10.csv', mock.endpoints[0], 'each part encoded, slashes kept');
    }

    @IsTest
    static void refusalsAreExplained() {
        S3Mock mock = new S3Mock();
        mock.responses.add(reply(403, '<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>'));
        mock.responses.add(reply(404, 'not xml'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        String denied = failureOf(mock);
        String missing = failureOf(mock);
        Test.stopTest();

        Assert.isTrue(denied.startsWith('S3 refused the request (403 AccessDenied): Access Denied.'), 'S3\'s own reason: ' + denied);
        Assert.isTrue(denied.contains('Check the access key'), 'and what to check: ' + denied);
        Assert.isTrue(missing.startsWith('S3 refused the request (404)'), 'no S3 document, just the status: ' + missing);
        Assert.isTrue(missing.contains('bucket and region'), 'what to check: ' + missing);
    }

    private static String failureOf(S3Mock mock) {
        try {
            new S3Storage().listFiles(source());
        } catch (CloudPullService.CloudException e) {
            return e.getMessage();
        }
        return 'no error';
    }
}
