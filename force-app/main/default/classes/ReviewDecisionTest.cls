@IsTest
private class ReviewDecisionTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    private static Import_Batch__c reviewBatch(List<Import_Staging_Row__c> rows) {
        Import_Batch__c batch = TradeTestWorld.stagedBatch('TEST', rows);
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    private static void decide(Id rowId, String decision) {
        update new Import_Staging_Row__c(Id = rowId, Reviewer_Decision__c = decision);
    }

    private static String errorOf(Import_Staging_Row__c change) {
        Database.SaveResult sr = Database.update(change, false);
        Assert.isFalse(sr.isSuccess(), 'the update should be refused');
        return sr.getErrors()[0].getMessage();
    }

    @IsTest
    static void acceptingClaudesFirmRematchesTheRow() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000) }
        );
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('FIRM_AMBIGUOUS', row.Match_Flags__c, 'two Kestrel firms');
        update new Import_Staging_Row__c(Id = row.Id, AI_Status__c = 'Suggested', AI_Suggested_Firm__c = w.kesInc.Id, AI_Confidence__c = 'High');

        Test.startTest();
        decide(row.Id, 'Accept');
        Import_Staging_Row__c pending = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Pending', pending.Match_Status__c, 'queued for re-matching');
        Assert.areEqual(w.kesInc.Id, pending.Firm_Override__c, 'suggestion copied to the override');
        Assert.areEqual(UserInfo.getUserId(), pending.Decided_By__c, 'decision stamped');
        Assert.isNotNull(pending.Decided_At__c, 'decision time stamped');
        Test.stopTest(); // runs the queued TradeMatcher

        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', done.Match_Status__c, 'matched after accept');
        Assert.areEqual('Claude', done.Match_Method__c, 'method records the accepted suggestion');
        Assert.areEqual('FIRM_FROM_CLAUDE', done.Match_Flags__c, 'flag');
        Assert.areEqual(w.ryan.Id, done.Credited_Advisor__c, 'credited to Ryan Chen');
        Assert.areEqual(w.wwfA.Id, done.Matched_Fund__c, 'fund');
        Assert.areEqual('Accept', done.Reviewer_Decision__c, 'decision kept for audit');
    }

    @IsTest
    static void aReviewersOwnChoiceIsRecordedAsTheirs() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000) }
        );
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        update new Import_Staging_Row__c(Id = row.Id, AI_Suggested_Firm__c = w.kesInc.Id, Firm_Override__c = w.kesLtd.Id, Reviewer_Decision__c = 'Accept');
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 1);
        // Ryan Chen does not hold code 1001 at Kestrel Capital Ltd., so the wrong choice is caught rather than loaded.
        Assert.areEqual('Held', done.Match_Status__c, 'wrong firm caught by the code check');
        Assert.isTrue(done.Match_Flags__c.startsWith('FIRM_FROM_REVIEWER'), 'reviewer choice recorded: ' + done.Match_Flags__c);
    }

    @IsTest
    static void acceptWithoutAFirmIsRefused() {
        TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000) }
        );
        String message = errorOf(new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 1).Id, Reviewer_Decision__c = 'Accept'));
        Assert.isTrue(message.contains('Choose a Firm Override'), 'error: ' + message);
    }

    @IsTest
    static void acceptWithoutAFundIsRefused() {
        TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'ETF Wealth World Fund A', SEP_29, 12500) }
        );
        String message = errorOf(new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 1).Id, Reviewer_Decision__c = 'Accept'));
        Assert.isTrue(message.contains('Choose a Fund Override'), 'error: ' + message);
    }

    @IsTest
    static void onlyRowsInReviewCanBeDecided() {
        TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World ETF', SEP_29, 1000) }
        );
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', row.Match_Status__c, 'clean row');
        String message = errorOf(new Import_Staging_Row__c(Id = row.Id, Reviewer_Decision__c = 'Reject'));
        Assert.isTrue(message.contains('Only rows in Needs Review'), 'error: ' + message);
    }

    @IsTest
    static void rejectedRowsAreExcluded() {
        TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000) }
        );
        Id rowId = TradeTestWorld.row(batch.Id, 1).Id;
        decide(rowId, 'Reject');
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Rejected', row.Match_Status__c, 'rejected');
        Assert.areEqual(UserInfo.getUserId(), row.Decided_By__c, 'who rejected it');
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Rejected', TradeTestWorld.row(batch.Id, 1).Match_Status__c, 'never re-matched');
    }

    @IsTest
    static void rememberedFundSpellingMatchesNextTime() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'ETF Wealth World Fund A', SEP_29, 12500) }
        );
        Id rowId = TradeTestWorld.row(batch.Id, 1).Id;
        update new Import_Staging_Row__c(Id = rowId, Fund_Override__c = w.wwEtf.Id, Remember_Choice__c = true, Reviewer_Decision__c = 'Accept');
        Fund_Alias__c taught = [SELECT Name, Normalized_Key__c, Fund__c FROM Fund_Alias__c WHERE Normalized_Key__c = 'etf wealth world fund a'];
        Assert.areEqual(w.wwEtf.Id, taught.Fund__c, 'alias points to the chosen fund');
        Assert.areEqual('ETF Wealth World Fund A', taught.Name, 'alias keeps the spelling from the file');

        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', done.Match_Status__c, 'accepted row matched');
        Assert.areEqual('Reviewer', done.Match_Method__c, 'reviewer chose the fund');

        Import_Batch__c next = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'ETF Wealth World Fund A', SEP_29, 900) }
        );
        Import_Staging_Row__c later = TradeTestWorld.row(next.Id, 1);
        Assert.areEqual('Matched', later.Match_Status__c, 'the next file matches by itself');
        Assert.areEqual('Exact', later.Match_Method__c, 'through the taught alias');
        Assert.areEqual(w.wwEtf.Id, later.Matched_Fund__c, 'to the same fund');
    }

    @IsTest
    static void ambiguousSpellingsAreNeverTaught() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000) }
        );
        Integer before = [SELECT COUNT() FROM Firm_Alias__c];
        update new Import_Staging_Row__c(
            Id = TradeTestWorld.row(batch.Id, 1).Id,
            Firm_Override__c = w.kesInc.Id,
            Remember_Choice__c = true,
            Reviewer_Decision__c = 'Accept'
        );
        Assert.areEqual(before, [SELECT COUNT() FROM Firm_Alias__c], 'an ambiguous name must keep going to review');
    }

    @IsTest
    static void aRowBackInReviewCanBeDecidedAgain() {
        TradeTestWorld.build();
        // Julia Morales started on code 457 in 2020, so a 2019 row cannot be credited until the data is fixed.
        Import_Batch__c batch = reviewBatch(
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Wealth World ETF', Date.newInstance(2019, 5, 1), 1000)
            }
        );
        Id rowId = TradeTestWorld.row(batch.Id, 1).Id;
        Assert.areEqual('DATE_BEFORE_CODE_START', TradeTestWorld.row(batch.Id, 1).Match_Flags__c, 'date before the code started');
        update new Import_Staging_Row__c(Id = rowId, AI_Status__c = 'Suggested', AI_Suggestion__c = 'Check the start date.');
        decide(rowId, 'Accept');
        Assert.areEqual('Pending', TradeTestWorld.row(batch.Id, 1).Match_Status__c, 'accept re-matches');
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c again = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Needs Review', again.Match_Status__c, 'still before the start date');
        Assert.isNull(again.Reviewer_Decision__c, 'decision cleared so it can be made again');
        Assert.isNull(again.AI_Status__c, 'Claude will be asked again');
        Assert.isNull(again.Decided_By__c, 'stale decision stamp cleared');
    }
}
