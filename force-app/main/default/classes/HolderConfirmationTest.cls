@IsTest
private class HolderConfirmationTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    /** Barder code 2210 (Marcus Bell) last confirmed in November 2025, and an unnamed trade on it: held as dormant. */
    private static Import_Batch__c dormantCode(TradeTestWorld w, Date endDate) {
        Rep_Code_Assignment__c marcus = [SELECT Id FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :w.b2210.Id];
        update new Rep_Code_Assignment__c(Id = marcus.Id, Last_Confirmed_Trade_Date__c = Date.newInstance(2025, 11, 14), Effective_End_Date__c = endDate);
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '2210', null, 'Wealth World ETF', SEP_29, 5000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    private static ReviewController.FollowUpItem itemFor(Id followUpId) {
        for (ReviewController.FollowUpItem f : ReviewController.getQueue('all').followUps) {
            if (f.id == followUpId) {
                return f;
            }
        }
        return null;
    }

    private static String confirmFailure(Id followUpId) {
        try {
            ReviewController.confirmHolder(followUpId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }

    @IsTest
    static void aReviewerConfirmsTheHolderAndTheRowsAreCredited() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = dormantCode(w, null);
        Import_Staging_Row__c held = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Held', held.Match_Status__c, 'held as dormant: ' + held.Match_Flags__c);
        Id reviewId = held.Code_Follow_Up__c;
        Code_Follow_Up__c fu = [SELECT Id, Reason__c FROM Code_Follow_Up__c WHERE Id = :reviewId];
        Assert.areEqual('Code Dormant', fu.Reason__c, 'a dormant code review');
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });

        Integer rematched;
        System.runAs(reviewer) {
            ReviewController.FollowUpItem item = itemFor(fu.Id);
            Assert.isTrue(item.canConfirmHolder, 'Confirm holder is offered');
            Assert.areEqual('Marcus Bell', item.holderNames, 'naming who holds the code today');
            Test.startTest();
            rematched = ReviewController.confirmHolder(fu.Id);
            Test.stopTest();
        }

        Assert.areEqual(1, rematched, 'one held row');
        Rep_Code_Assignment__c a = [SELECT Holder_Confirmed_On__c, Holder_Confirmed_By__c FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :w.b2210.Id];
        Assert.areEqual(System.today(), a.Holder_Confirmed_On__c, 'the confirmation is dated');
        Assert.areEqual(reviewer.Id, a.Holder_Confirmed_By__c, 'and says who recorded it');
        Code_Follow_Up__c after = [SELECT Status__c, Resolution_Notes__c FROM Code_Follow_Up__c WHERE Id = :fu.Id];
        Assert.areEqual('Resolved', after.Status__c, 'the review is settled');
        Assert.isTrue(after.Resolution_Notes__c.contains('The firm confirmed Marcus Bell still holds code 2210'), 'noted: ' + after.Resolution_Notes__c);
        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', row.Match_Status__c, 'matched again: ' + row.Match_Flags__c);
        Assert.areEqual(w.marcus.Id, row.Credited_Advisor__c, 'credited to the holder');
    }

    @IsTest
    static void aConfirmationKeepsTheCodeFromLookingDormant() {
        Rep_Code_Assignment__c a = new Rep_Code_Assignment__c(
            Last_Confirmed_Trade_Date__c = Date.newInstance(2025, 1, 1),
            Holder_Confirmed_On__c = Date.newInstance(2026, 9, 1)
        );
        List<Rep_Code_Assignment__c> active = new List<Rep_Code_Assignment__c>{ a };
        Assert.isFalse(TradeMatcher.isDormant(active, Date.newInstance(2026, 12, 1)), 'confirmed three months before the row');
        Assert.isTrue(TradeMatcher.isDormant(active, Date.newInstance(2027, 6, 1)), 'more than 180 days after the confirmation');
        a.Holder_Confirmed_On__c = null;
        Assert.isTrue(TradeMatcher.isDormant(active, Date.newInstance(2026, 12, 1)), 'without it, the last trade decides');
    }

    @IsTest
    static void onlyADormantReviewWithAHolderTodayCanBeConfirmed() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        // Marcus held 2210 on the trade date but gave it up since, so nobody holds it today.
        Import_Batch__c ended = dormantCode(w, System.today().addDays(-1));
        Import_Batch__c unknown = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '7001', 'Julia Morales', 'Wealth World ETF', SEP_29, 1000) }
        );
        TradeMatcher.run(new Set<Id>{ unknown.Id });
        Id endedReview = TradeTestWorld.row(ended.Id, 1).Code_Follow_Up__c;
        Id unknownReview = TradeTestWorld.row(unknown.Id, 1).Code_Follow_Up__c;

        Test.startTest();
        ReviewController.FollowUpItem endedItem = itemFor(endedReview);
        ReviewController.FollowUpItem unknownItem = itemFor(unknownReview);
        String nobody = confirmFailure(endedReview);
        String notDormant = confirmFailure(unknownReview);
        Test.stopTest();

        Assert.isFalse(endedItem.canConfirmHolder, 'nobody to confirm');
        Assert.isFalse(unknownItem.canConfirmHolder, 'not a dormant code');
        Assert.isTrue(nobody.contains('Nobody holds code 2210 today'), 'says why: ' + nobody);
        Assert.isTrue(notDormant.contains('dormant code review only'), 'says why: ' + notDormant);
        Assert.areEqual('Open', [SELECT Status__c FROM Code_Follow_Up__c WHERE Id = :endedReview].Status__c, 'still open');
    }
}
