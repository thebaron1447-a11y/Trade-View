@IsTest
private class StrandedWorkSweeperTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    /** A staged Barder file whose rows were never matched: one clean trade and one unknown fund spelling. */
    private static Import_Batch__c unmatchedFile() {
        TradeTestWorld.build();
        return TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_29, 2000)
            }
        );
    }

    @IsTest
    static void rowsLeftPendingAreMatched() {
        AiSettings.current = new AiSettings();
        Import_Batch__c batch = unmatchedFile();
        StrandedWorkSweeper.quietMinutes = -1;

        Test.startTest();
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();
        Test.stopTest();

        Assert.areEqual(1, r.batchesRematched, 'the file with Pending rows is matched again');
        Assert.isFalse(r.claudeRestarted, 'Claude is off');
        Assert.areEqual('Matched', TradeTestWorld.row(batch.Id, 1).Match_Status__c, 'the clean trade matched');
        Assert.areEqual('Needs Review', TradeTestWorld.row(batch.Id, 2).Match_Status__c, 'the unknown fund went to review');
    }

    @IsTest
    static void filesNeverStagedAreProcessed() {
        AiSettings.current = new AiSettings();
        Import_Batch__c batch = TestDataFactory.receivedBatch('HARBOUR', 'Representative,Rep No.,Value\r\nRyan Chen,1001,100\r\n');
        StrandedWorkSweeper.quietMinutes = -1;

        Test.startTest();
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();
        Test.stopTest();

        Assert.areEqual(1, r.filesRestarted, 'the Received file is processed');
        Assert.areEqual(
            ImportBatchProcessor.STATUS_MAPPING_REVIEW,
            [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c,
            'processed: an unknown layout waits for a mapping'
        );
    }

    @IsTest
    static void workThatIsStillFreshIsLeftAlone() {
        AiSettings.current = new AiSettings();
        unmatchedFile();
        TestDataFactory.receivedBatch('HARBOUR', 'Representative,Rep No.,Value\r\nRyan Chen,1001,100\r\n');

        // The default quiet time: everything was touched just now, so a job may still be on its way.
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();

        Assert.areEqual(0, r.filesRestarted, 'no file restarted');
        Assert.areEqual(0, r.batchesRematched, 'no rows rematched');
        Assert.areEqual(0, Limits.getQueueableJobs(), 'nothing queued');
    }

    @IsTest
    static void itemsClaudeWasNeverAskedAboutAreSent() {
        AiSettings.current = new AiSettings();
        Import_Batch__c batch = unmatchedFile();
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c open = TradeTestWorld.row(batch.Id, 2);
        Assert.isNull(open.AI_Status__c, 'fixture: Claude was off, so the open row was never sent');
        FakeClaudeClient.install(new List<Object>{ '{"suggestions": []}' });
        StrandedWorkSweeper.quietMinutes = -1;

        Test.startTest();
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();
        Test.stopTest();

        Assert.isTrue(r.claudeRestarted, 'Claude is asked about the waiting row');
        Assert.areEqual(0, r.batchesRematched, 'no Pending rows were left');
        Assert.isNotNull(TradeTestWorld.row(batch.Id, 2).AI_Status__c, 'the row now has an answer status');
    }

    @IsTest
    static void loadsLeftPartWayAreFinished() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        // Load file was clicked, but the job that books the rows never ran.
        SystemWriter.updateOne(new Import_Batch__c(Id = batch.Id, Status__c = TradeLoader.STATUS_LOADING));
        StrandedWorkSweeper.quietMinutes = -1;

        Test.startTest();
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();
        Test.stopTest();

        Assert.areEqual(1, r.loadsRestarted, 'the load is restarted');
        Assert.areEqual(1, [SELECT COUNT() FROM Trade__c], 'the trade is booked');
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c, 'and the file finished');
    }

    @IsTest
    static void schedulingReplacesEarlierSchedules() {
        String pattern = StrandedWorkSweeper.JOB_NAME + '%';
        Assert.areEqual(4, StrandedWorkSweeper.scheduleEvery15Minutes().size(), 'four runs an hour');
        StrandedWorkSweeper.scheduleEvery15Minutes();
        Assert.areEqual(4, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :pattern], 'scheduling twice keeps four');
        StrandedWorkSweeper.unschedule();
        Assert.areEqual(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :pattern], 'unscheduled');
    }
}
