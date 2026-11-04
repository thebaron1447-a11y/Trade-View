@IsTest
private class CodeReviewHoldTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);
    private static final String QUESTION = 'Please confirm who holds code 2210 at Barder & Company today.';

    /** Barder code 2210 (Marcus Bell) last confirmed in November 2025, and an unnamed trade on it: held as dormant. */
    private static Id dormantReview(TradeTestWorld w) {
        Rep_Code_Assignment__c marcus = [SELECT Id FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :w.b2210.Id];
        update new Rep_Code_Assignment__c(Id = marcus.Id, Last_Confirmed_Trade_Date__c = Date.newInstance(2025, 11, 14));
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '2210', null, 'Wealth World ETF', SEP_29, 5000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c held = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Held', held.Match_Status__c, 'held as dormant: ' + held.Match_Flags__c);
        return held.Code_Follow_Up__c;
    }

    private static ReviewController.FollowUpItem itemFor(ReviewController.Queue q, Id followUpId) {
        for (ReviewController.FollowUpItem f : q.followUps) {
            if (f.id == followUpId) {
                return f;
            }
        }
        return null;
    }

    private static ReviewController.FirmQuestion questionFor(ReviewController.Queue q, Id itemId) {
        for (ReviewController.FirmFollowUp firm : q.firmFollowUps) {
            for (ReviewController.FirmQuestion fq : firm.questions) {
                if (fq.itemId == itemId) {
                    return fq;
                }
            }
        }
        return null;
    }

    private static String failure(Id followUpId, String homework, Boolean release) {
        try {
            if (release) {
                ReviewController.releaseCodeReviewHold(followUpId);
            } else {
                ReviewController.holdCodeReview(followUpId, homework);
            }
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }

    @IsTest
    static void aReviewerPutsACodeReviewOnHoldAndReleasesIt() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Id reviewId = dormantReview(w);
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });
        String reviewerName = [SELECT Name FROM User WHERE Id = :reviewer.Id].Name;

        ReviewController.Queue held;
        String releaseAgain;
        Test.startTest();
        System.runAs(reviewer) {
            ReviewController.holdCodeReview(reviewId, '  ' + QUESTION + '  ');
            held = ReviewController.getQueue('all');
        }
        Code_Follow_Up__c onHold = [
            SELECT On_Hold__c, On_Hold_Reason__c, On_Hold_By__c, On_Hold_Since__c, Status__c, Resolution_Notes__c
            FROM Code_Follow_Up__c
            WHERE Id = :reviewId
        ];
        System.runAs(reviewer) {
            ReviewController.releaseCodeReviewHold(reviewId);
            releaseAgain = failure(reviewId, null, true);
        }
        Test.stopTest();

        Assert.isTrue(onHold.On_Hold__c, 'on hold');
        Assert.areEqual(QUESTION, onHold.On_Hold_Reason__c, 'the question, trimmed');
        Assert.areEqual(reviewer.Id, onHold.On_Hold_By__c, 'stamped with who');
        Assert.isNotNull(onHold.On_Hold_Since__c, 'and when');
        Assert.areEqual('In Progress', onHold.Status__c, 'being chased');
        Assert.isTrue(onHold.Resolution_Notes__c.startsWith('Put on hold until the firm answers'), 'noted: ' + onHold.Resolution_Notes__c);

        ReviewController.FollowUpItem item = itemFor(held, reviewId);
        Assert.isTrue(item.onHold, 'the app shows it on hold');
        Assert.areEqual(QUESTION, item.holdReason, 'with its question');
        Assert.areEqual(reviewerName, item.heldByName, 'and who held it');
        ReviewController.FirmQuestion fq = questionFor(held, reviewId);
        Assert.areEqual(QUESTION, fq.text, 'the firm is asked the reviewer\'s question');
        Assert.isTrue(fq.source.startsWith('On hold · Code 2210'), 'marked as on hold: ' + fq.source);

        Code_Follow_Up__c released = [SELECT On_Hold__c, On_Hold_Reason__c, Status__c, Resolution_Notes__c FROM Code_Follow_Up__c WHERE Id = :reviewId];
        Assert.isFalse(released.On_Hold__c, 'released');
        Assert.areEqual(QUESTION, released.On_Hold_Reason__c, 'the question stays for the record');
        Assert.areEqual('In Progress', released.Status__c, 'still open');
        Assert.isTrue(released.Resolution_Notes__c.startsWith('Released from hold'), 'noted: ' + released.Resolution_Notes__c);
        Assert.isTrue(releaseAgain.contains('not on hold'), 'says why: ' + releaseAgain);
        Assert.areEqual(
            'Held',
            [SELECT Match_Status__c FROM Import_Staging_Row__c WHERE Code_Follow_Up__c = :reviewId LIMIT 1].Match_Status__c,
            'the row stays held throughout'
        );
    }

    @IsTest
    static void settlingAReviewTakesItOffHold() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Id reviewId = dormantReview(w);
        ReviewController.holdCodeReview(reviewId, QUESTION);

        Test.startTest();
        ReviewController.confirmHolder(reviewId);
        Test.stopTest();

        Code_Follow_Up__c after = [SELECT On_Hold__c, Status__c FROM Code_Follow_Up__c WHERE Id = :reviewId];
        Assert.areEqual('Resolved', after.Status__c, 'settled');
        Assert.isFalse(after.On_Hold__c, 'and no longer on hold');
    }

    @IsTest
    static void aHoldNeedsAQuestionAndCannotBeStampedByHand() {
        AiSettings.current = new AiSettings();
        TradeTestWorld w = TradeTestWorld.build();
        Id reviewId = dormantReview(w);
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });

        String blank;
        Boolean refused = false;
        Test.startTest();
        System.runAs(reviewer) {
            blank = failure(reviewId, '   ', false);
            try {
                // System mode, so only the trigger guard stands in the way.
                update new Code_Follow_Up__c(Id = reviewId, On_Hold_Since__c = System.now().addDays(-30));
            } catch (DmlException e) {
                refused = e.getMessage().contains('set by the system');
            }
        }
        Test.stopTest();

        Assert.isTrue(blank.contains('Say what needs to be found out'), 'says why: ' + blank);
        Assert.isTrue(refused, 'On Hold Since is set by the system only');
        Assert.isFalse([SELECT On_Hold__c FROM Code_Follow_Up__c WHERE Id = :reviewId].On_Hold__c, 'not on hold');
    }
}
