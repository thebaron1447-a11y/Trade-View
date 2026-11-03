@IsTest
private class TradeViewNotifierTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    /** A staged Barder file: one clean trade and one unknown fund spelling. */
    private static Import_Batch__c stagedFile() {
        TradeTestWorld.build();
        return TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_29, 2000)
            }
        );
    }

    /** Someone uploaded the file (the push job does not set a row count on staged test batches, so it is set here). */
    private static void waitFor(Id batchId, Integer rowCount) {
        SystemWriter.updateOne(new Import_Batch__c(Id = batchId, Notify_User__c = UserInfo.getUserId(), Row_Count__c = rowCount));
    }

    private static Id notifyUser(Id batchId) {
        return [SELECT Notify_User__c FROM Import_Batch__c WHERE Id = :batchId].Notify_User__c;
    }

    @IsTest
    static void whoeverWaitsHearsOnceWhenTheFileIsMatched() {
        AiSettings.current = new AiSettings();
        Import_Batch__c batch = stagedFile();
        waitFor(batch.Id, 2);

        Test.startTest();
        TradeMatcher.run(new Set<Id>{ batch.Id });
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Test.stopTest();

        Assert.areEqual(1, TradeViewNotifier.sent.size(), 'one bell, however often the file is matched again');
        TradeViewNotifier.Sent s = TradeViewNotifier.sent[0];
        Assert.areEqual(UserInfo.getUserId(), s.userId, 'to the person waiting');
        Assert.isTrue(s.title.startsWith('File ready: BARDER'), 'says which file: ' + s.title);
        Assert.areEqual('2 rows: 1 matched, 1 to review, 0 held, 0 invalid.', s.body, 'and how it went');
        Assert.isNull(notifyUser(batch.Id), 'nobody is waiting any more');
    }

    @IsTest
    static void filesThePushJobSendsNotifyNobody() {
        AiSettings.current = new AiSettings();
        Import_Batch__c batch = stagedFile();

        Test.startTest();
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Test.stopTest();

        Assert.isTrue(TradeViewNotifier.sent.isEmpty(), 'no Notify User, no bell');
    }

    @IsTest
    static void whoeverClicksLoadFileHearsWhenItIsBooked() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });

        Test.startTest();
        ReviewController.loadFile(batch.Id);
        Assert.areEqual(UserInfo.getUserId(), notifyUser(batch.Id), 'the loader is waiting');
        TradeLoader.loadNext(batch.Id);
        Test.stopTest();

        Assert.areEqual(1, TradeViewNotifier.sent.size(), 'one bell');
        Assert.isTrue(TradeViewNotifier.sent[0].title.startsWith('File booked:'), 'title: ' + TradeViewNotifier.sent[0].title);
        Assert.areEqual('1 row loaded. Nothing in the file is waiting.', TradeViewNotifier.sent[0].body, 'what was booked');
        Assert.isNull(notifyUser(batch.Id), 'cleared');
    }

    @IsTest
    static void theUploaderIsWaitingUntilTheFileIsRead() {
        AiSettings.current = new AiSettings();
        String content = EncodingUtil.base64Encode(Blob.valueOf('Representative,Rep No.\nRyan Chen,1001\n'));

        Test.startTest();
        FileIntakeService.Receipt r = ReviewController.uploadFile('HARBOUR', 'harbour.csv', content);
        Assert.areEqual(UserInfo.getUserId(), notifyUser(r.batchId), 'the uploader waits for it');
        Test.stopTest();

        Import_Batch__c b = [SELECT Status__c, Notify_User__c FROM Import_Batch__c WHERE Id = :r.batchId];
        Assert.areEqual('Mapping Review', b.Status__c, 'an unknown layout');
        Assert.isNull(b.Notify_User__c, 'told that the layout needs a mapping');
    }

    @IsTest
    static void eachMomentSaysWhatHappened() {
        Import_Batch__c b = new Import_Batch__c(Source_Firm__c = 'BARDER', Source_File_Name__c = 'trades.csv', Notify_User__c = UserInfo.getUserId());

        b.Status__c = 'Failed';
        b.Error_Message__c = 'The file is not valid UTF-8 text.';
        TradeViewNotifier.Sent failed = TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_READ);
        Assert.areEqual('File could not be read: BARDER · trades.csv', failed.title, 'failed');
        Assert.areEqual('The file is not valid UTF-8 text.', failed.body, 'with the reason');

        b.Status__c = 'Mapping Review';
        Assert.isTrue(TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_READ).title.startsWith('New file format'), 'mapping');

        b.Status__c = 'Pending Review';
        b.Loaded_Row_Count__c = 3;
        b.Error_Message__c = 'Loading stopped and nothing in the last 2 rows was saved: boom';
        TradeViewNotifier.Sent stopped = TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_LOADED);
        Assert.isTrue(stopped.title.startsWith('Loading stopped:'), 'title: ' + stopped.title);
        b.Error_Message__c = null;
        Assert.isTrue(TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_LOADED).body.startsWith('3 rows loaded so far.'), 'part loaded');

        b.Status__c = 'Staged';
        Assert.isNull(TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_READ), 'still being worked on: nothing to say yet');
        b.Status__c = 'Loading';
        Assert.isNull(TradeViewNotifier.message(b, TradeViewNotifier.MOMENT_LOADED), 'nor while loading');
    }

    @IsTest
    static void publishingNeverFails() {
        Test.startTest();
        TradeViewNotifier.changed(TradeViewNotifier.KIND_ROWS, null);
        TradeViewNotifier.changed(TradeViewNotifier.KIND_FILE, UserInfo.getUserId());
        TradeViewNotifier.fileSettled(null, TradeViewNotifier.MOMENT_READ);
        Test.stopTest();
        Assert.isTrue(TradeViewNotifier.sent.isEmpty(), 'nothing to notify');
    }
}
