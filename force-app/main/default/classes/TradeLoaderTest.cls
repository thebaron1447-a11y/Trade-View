@IsTest
private class TradeLoaderTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);
    private static final Date SEP_30 = Date.newInstance(2026, 9, 30);

    /** Barder team code T900: Julia Morales 60%, Marcus Bell 40%. */
    private static Rep_Code__c teamCode(TradeTestWorld w) {
        Rep_Code__c team = new Rep_Code__c(Name = 'T900', Firm__c = w.barder.Id);
        insert team;
        insert new List<Rep_Code_Assignment__c>{
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.julia.Id,
                Allocation_Percent__c = 60,
                Effective_Start_Date__c = Date.newInstance(2024, 1, 1)
            ),
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.marcus.Id,
                Allocation_Percent__c = 40,
                Effective_Start_Date__c = Date.newInstance(2024, 1, 1)
            )
        };
        return team;
    }

    private static Import_Staging_Row__c aum(String code, String fund, Date d, Decimal balance) {
        Import_Staging_Row__c r = TradeTestWorld.trade('Barder & Company', code, null, fund, d, balance);
        r.Row_Type__c = 'AUM';
        r.Transaction_Type__c = null;
        return r;
    }

    /** A matched Barder file with these rows. */
    private static Import_Batch__c matchedFile(List<Import_Staging_Row__c> rows) {
        Import_Batch__c batch = TradeTestWorld.stagedBatch('BARDER', rows);
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    private static Import_Batch__c batchOf(Id batchId) {
        return [SELECT Status__c, Loaded_Row_Count__c, Error_Message__c FROM Import_Batch__c WHERE Id = :batchId];
    }

    private static Import_Staging_Row__c loadState(Id batchId, Integer rowNumber) {
        return [
            SELECT Match_Status__c, Match_Notes__c, Loaded_At__c, Loaded_Trade__c, Loaded_AUM_Balance__c
            FROM Import_Staging_Row__c
            WHERE Import_Batch__c = :batchId AND Row_Number__c = :rowNumber
        ];
    }

    private static Map<Id, Decimal> tradeSplit(Id tradeId) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        for (Trade_Allocation__c a : [SELECT Advisor__c, Allocated_Amount__c FROM Trade_Allocation__c WHERE Trade__c = :tradeId]) {
            result.put(a.Advisor__c, a.Allocated_Amount__c);
        }
        return result;
    }

    private static String loadFailure(Id batchId) {
        try {
            ReviewController.loadFile(batchId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }

    private static ReviewController.FileItem fileOf(Id batchId) {
        for (ReviewController.FileItem f : ReviewController.getQueue('all').recentFiles) {
            if (f.id == batchId) {
                return f;
            }
        }
        return null;
    }

    @IsTest
    static void aSoloTradeIsBookedToItsAdvisor() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        ReviewController.FileItem before = fileOf(batch.Id);
        Assert.areEqual(1, before.loadableCount, 'one row ready');
        Assert.isTrue(before.canLoad, 'Load file is offered');

        Test.startTest();
        Integer ready = ReviewController.loadFile(batch.Id);
        Assert.areEqual(TradeLoader.STATUS_LOADING, batchOf(batch.Id).Status__c, 'loading in the background');
        Test.stopTest();

        Assert.areEqual(1, ready, 'one row to load');
        Import_Staging_Row__c row = loadState(batch.Id, 1);
        Assert.isNotNull(row.Loaded_At__c, 'stamped');
        Id tradeId = row.Loaded_Trade__c;
        Trade__c t = [
            SELECT Rep_Code__c, Fund__c, Trade_Date__c, Transaction_Type__c, Amount__c, Signed_Amount__c, Source_Row__c, Load_Key__c
            FROM Trade__c
            WHERE Id = :tradeId
        ];
        Assert.areEqual(w.b457.Id, t.Rep_Code__c, 'the code');
        Assert.areEqual(w.wwfA.Id, t.Fund__c, 'the fund');
        Assert.areEqual(SEP_29, t.Trade_Date__c, 'the date');
        Assert.areEqual(1000.00, t.Signed_Amount__c, 'a purchase');
        Assert.areEqual((String) t.Source_Row__c, t.Load_Key__c, 'keyed by its row');
        Map<Id, Decimal> split = tradeSplit(t.Id);
        Assert.areEqual(1, split.size(), 'one advisor');
        Assert.areEqual(1000.00, split.get(w.julia.Id), '100% to Julia');
        Import_Batch__c b = batchOf(batch.Id);
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, b.Status__c, 'nothing is waiting, so the file is booked');
        Assert.areEqual(1, b.Loaded_Row_Count__c.intValue(), 'counted');
        Assert.isFalse(fileOf(batch.Id).canLoad, 'nothing more to load');
    }

    @IsTest
    static void aTeamTradeSplitsToTheCent() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        teamCode(w);
        Import_Staging_Row__c sale = TradeTestWorld.trade('Barder & Company', 'T900', null, 'Wealth World ETF', SEP_30, 100.01);
        sale.Transaction_Type__c = 'Redemption';
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', 'T900', null, 'Wealth World ETF', SEP_29, 1000.01), sale }
        );

        Test.startTest();
        ReviewController.loadFile(batch.Id);
        Test.stopTest();

        Map<Id, Decimal> buy = tradeSplit(loadState(batch.Id, 1).Loaded_Trade__c);
        Assert.areEqual(600.01, buy.get(w.julia.Id), '60% takes the leftover cent');
        Assert.areEqual(400.00, buy.get(w.marcus.Id), '40%');
        Map<Id, Decimal> redemption = tradeSplit(loadState(batch.Id, 2).Loaded_Trade__c);
        Assert.areEqual(-60.01, redemption.get(w.julia.Id), 'redemptions are negative');
        Assert.areEqual(-40.00, redemption.get(w.marcus.Id), 'and still add up');
        AggregateResult total = [SELECT SUM(Allocated_Amount__c) s FROM Trade_Allocation__c WHERE Advisor__c = :w.julia.Id];
        Assert.areEqual(540.00, (Decimal) total.get('s'), 'net sales for Julia');
    }

    @IsTest
    static void aBalanceSentAgainReplacesTheEarlierOne() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c first = matchedFile(new List<Import_Staging_Row__c>{ aum('457', 'Wealth World Fund - Series A', SEP_30, 5000) });
        ReviewController.loadFile(first.Id);
        TradeLoader.loadNext(first.Id);
        Import_Batch__c second = matchedFile(new List<Import_Staging_Row__c>{ aum('457', 'Wealth World Fund - Series A', SEP_30, 7000) });

        Test.startTest();
        ReviewController.loadFile(second.Id);
        Test.stopTest();

        List<AUM_Balance__c> balances = [SELECT Id, Balance__c, As_Of_Date__c, Rep_Code__c, Fund__c, Source_Row__c FROM AUM_Balance__c];
        Assert.areEqual(1, balances.size(), 'one balance per code, fund and date');
        AUM_Balance__c bal = balances[0];
        Assert.areEqual(7000.00, bal.Balance__c, 'the later figure');
        Assert.areEqual(w.b457.Id, bal.Rep_Code__c, 'the code');
        List<AUM_Allocation__c> split = [SELECT Advisor__c, Allocated_Balance__c FROM AUM_Allocation__c WHERE AUM_Balance__c = :bal.Id];
        Assert.areEqual(1, split.size(), 'the earlier split is replaced, not added to');
        Assert.areEqual(7000.00, split[0].Allocated_Balance__c, 'all to Julia');
        Assert.areEqual(w.julia.Id, split[0].Advisor__c, 'Julia holds the code');
        Import_Staging_Row__c latest = loadState(second.Id, 1);
        Assert.areEqual(bal.Id, latest.Loaded_AUM_Balance__c, 'the new row points to it');
        Assert.areEqual(bal.Id, loadState(first.Id, 1).Loaded_AUM_Balance__c, 'and so does the earlier row');
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, batchOf(second.Id).Status__c, 'booked');
    }

    @IsTest
    static void loadingAgainNeverBooksARowTwice() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        ReviewController.loadFile(batch.Id);
        TradeLoader.loadNext(batch.Id);

        Test.startTest();
        String again = loadFailure(batch.Id);
        // Even a load forced to run again finds nothing left to book.
        SystemWriter.updateOne(new Import_Batch__c(Id = batch.Id, Status__c = TradeLoader.STATUS_LOADING));
        TradeLoader.loadNext(batch.Id);
        Test.stopTest();

        Assert.isTrue(again.contains('This file is Completed'), 'a booked file cannot be loaded again: ' + again);
        Assert.areEqual(1, [SELECT COUNT() FROM Trade__c], 'one trade');
        Assert.areEqual(1, [SELECT COUNT() FROM Trade_Allocation__c], 'one allocation');
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, batchOf(batch.Id).Status__c, 'still booked');
    }

    @IsTest
    static void rowsStillWaitingLoadWithALaterLoad() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_29, 2000)
            }
        );
        Assert.areEqual('Needs Review', loadState(batch.Id, 2).Match_Status__c, 'the unknown fund waits for a person');
        ReviewController.loadFile(batch.Id);
        TradeLoader.loadNext(batch.Id);
        Assert.areEqual(TradeMatcher.STATUS_PENDING_REVIEW, batchOf(batch.Id).Status__c, 'a row is still waiting');
        Assert.isNull(loadState(batch.Id, 2).Loaded_At__c, 'not loaded');

        // A reviewer picks the fund; matching settles the row.
        update new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 2).Id, Fund_Override__c = w.wwEtf.Id, Reviewer_Decision__c = 'Accept');
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Matched', loadState(batch.Id, 2).Match_Status__c, 'decided');

        Test.startTest();
        Integer ready = ReviewController.loadFile(batch.Id);
        Test.stopTest();

        Assert.areEqual(1, ready, 'only the newly matched row');
        Assert.areEqual(2, [SELECT COUNT() FROM Trade__c], 'both trades booked, once each');
        Import_Batch__c b = batchOf(batch.Id);
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, b.Status__c, 'now complete');
        Assert.areEqual(2, b.Loaded_Row_Count__c.intValue(), 'both rows counted');
    }

    @IsTest
    static void aSplitChangedAfterMatchingGoesBackToMatching() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Rep_Code__c team = teamCode(w);
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', 'T900', null, 'Wealth World ETF', SEP_29, 1000) }
        );
        Assert.areEqual('Matched', loadState(batch.Id, 1).Match_Status__c, 'split 60/40 when matched');
        Rep_Code_Assignment__c marcus = [SELECT Id FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :team.Id AND Advisor__c = :w.marcus.Id];
        update new Rep_Code_Assignment__c(Id = marcus.Id, Allocation_Percent__c = 30);

        Test.startTest();
        ReviewController.loadFile(batch.Id);
        Test.stopTest();

        Import_Staging_Row__c row = loadState(batch.Id, 1);
        Assert.areEqual(0, [SELECT COUNT() FROM Trade__c], 'nothing booked on a split that does not add up');
        Assert.areEqual('Pending', row.Match_Status__c, 'sent back to matching');
        Assert.isTrue(row.Match_Notes__c.startsWith('Not loaded on'), 'says why: ' + row.Match_Notes__c);
        Assert.areEqual(TradeMatcher.STATUS_PENDING_REVIEW, batchOf(batch.Id).Status__c, 'the file waits');
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Held', loadState(batch.Id, 1).Match_Status__c, 'matching holds it behind the incomplete split');
    }

    @IsTest
    static void aReviewerCanLoadAndSeeWhatWasBooked() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000),
                aum('2210', null, SEP_30, 25000)
            }
        );
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });

        System.runAs(reviewer) {
            Test.startTest();
            Assert.areEqual(2, ReviewController.loadFile(batch.Id), 'a trade and a balance');
            Test.stopTest();
            Assert.areEqual(1, [SELECT COUNT() FROM Trade_Allocation__c WITH USER_MODE], 'reads the allocation');
            AUM_Balance__c bal = [SELECT Balance__c, Fund__c, Balance_Key__c FROM AUM_Balance__c WITH USER_MODE];
            Assert.areEqual(25000.00, bal.Balance__c, 'reads the balance');
            Assert.isNull(bal.Fund__c, 'a total for the code');
            Assert.isTrue(bal.Balance_Key__c.endsWith('|ALL|2026-09-30'), 'keyed for all funds: ' + bal.Balance_Key__c);
            Assert.areEqual(25000.00, [SELECT Allocated_Balance__c FROM AUM_Allocation__c WITH USER_MODE].Allocated_Balance__c, 'all to Marcus');
            // A booked row is locked, even in system mode.
            Import_Staging_Row__c row = loadState(batch.Id, 1);
            try {
                update new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 1).Id, Match_Status__c = 'Pending');
                Assert.fail('a loaded row cannot be re-matched');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains('cannot be changed by hand') || e.getMessage().contains('already loaded'), 'refused: ' + e.getMessage());
            }
            Assert.isNotNull(row.Loaded_At__c, 'loaded');
        }
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, batchOf(batch.Id).Status__c, 'booked');
    }

    @IsTest
    static void aLoadedRowStaysLockedForTheSystemToo() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c batch = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        ReviewController.loadFile(batch.Id);
        TradeLoader.loadNext(batch.Id);
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });
        Id rowId = TradeTestWorld.row(batch.Id, 1).Id;

        Test.startTest();
        System.runAs(reviewer) {
            try {
                SystemWriter.updateOne(new Import_Staging_Row__c(Id = rowId, Match_Status__c = 'Pending'));
                Assert.fail('the system writer cannot re-match a booked row either');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains('already loaded'), 'refused: ' + e.getMessage());
            }
        }
        Test.stopTest();
        Assert.areEqual('Matched', loadState(batch.Id, 1).Match_Status__c, 'unchanged');
    }

    @IsTest
    static void onlyAFileThatFinishedMatchingCanLoad() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        Import_Batch__c staged = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 1000) }
        );
        Import_Batch__c review = matchedFile(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_29, 2000) }
        );

        Test.startTest();
        String notMatched = loadFailure(staged.Id);
        String nothingReady = loadFailure(review.Id);
        String notAFile = loadFailure(null);
        Test.stopTest();

        Assert.isTrue(notMatched.contains('once matching has finished'), 'not matched yet: ' + notMatched);
        Assert.isTrue(nothingReady.contains('No matched rows are waiting'), 'nothing ready: ' + nothingReady);
        Assert.isTrue(notAFile.contains('Choose a file'), 'no file: ' + notAFile);
        Assert.areEqual(0, [SELECT COUNT() FROM Trade__c], 'nothing booked');
    }

    @IsTest
    static void largeFilesLoadInChunks() {
        AiSettings.current = new AiSettings();
        TradeTestWorld.build();
        List<Import_Staging_Row__c> rows = new List<Import_Staging_Row__c>();
        for (Integer i = 1; i <= 5; i++) {
            rows.add(TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World Fund - Series A', SEP_29, 100 * i));
        }
        Import_Batch__c batch = matchedFile(rows);
        TradeLoader.chunkSize = 2;
        ReviewController.loadFile(batch.Id);

        Test.startTest();
        Assert.isTrue(TradeLoader.loadNext(batch.Id), 'two loaded, more to come');
        Assert.areEqual(TradeLoader.STATUS_LOADING, batchOf(batch.Id).Status__c, 'still loading');
        Assert.areEqual(2, batchOf(batch.Id).Loaded_Row_Count__c.intValue(), 'progress is counted');
        Assert.isTrue(TradeLoader.loadNext(batch.Id), 'four loaded');
        Assert.isFalse(TradeLoader.loadNext(batch.Id), 'the last one');
        Test.stopTest();

        Assert.areEqual(5, [SELECT COUNT() FROM Trade__c], 'every row once');
        Assert.areEqual(TradeLoader.STATUS_COMPLETED, batchOf(batch.Id).Status__c, 'booked');
    }
}
