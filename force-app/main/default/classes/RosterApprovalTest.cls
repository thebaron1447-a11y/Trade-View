@IsTest
private class RosterApprovalTest {
    private static Import_Batch__c matched(List<Import_Staging_Row__c> rows) {
        Import_Batch__c batch = TradeTestWorld.stagedBatch('BARDER', rows);
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    @IsTest
    static void newCodeAndNewAdvisorAreSetUpAndHeldTradesRelease() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c trades = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '3390', 'Hannah Pierce', 'Wealth World ETF', Date.newInstance(2026, 9, 27), 45000) }
        );
        Assert.areEqual('Held', TradeTestWorld.row(trades.Id, 1).Match_Status__c, 'unknown code held');
        Import_Batch__c roster = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.roster('Barder & Company', '3390', 'Hannah Pierce', 'Barder & Company - Oakville', Date.newInstance(2026, 9, 20)) }
        );
        Import_Staging_Row__c rosterRow = TradeTestWorld.row(roster.Id, 1);
        Assert.areEqual('Needs Review', rosterRow.Match_Status__c, 'roster row waits for approval');
        Assert.areEqual('NEW_ADVISOR;ROSTER_NEW_CODE', rosterRow.Match_Flags__c, 'new advisor and new code');

        Test.startTest();
        update new Import_Staging_Row__c(Id = rosterRow.Id, Reviewer_Decision__c = 'Accept');
        Test.stopTest(); // the resolved follow-up queues re-matching of the held trade

        Contact hannah = [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE LastName = 'Pierce'];
        Assert.areEqual('Hannah', hannah.FirstName, 'first name');
        Assert.areEqual(w.barderOakville.Id, hannah.AccountId, 'placed at the branch named in the roster');
        Rep_Code__c code = [SELECT Id, (SELECT Advisor__c, Allocation_Percent__c, Effective_Start_Date__c FROM Assignments__r) FROM Rep_Code__c WHERE Name = '3390'];
        Assert.areEqual(1, code.Assignments__r.size(), 'one assignment');
        Assert.areEqual(hannah.Id, code.Assignments__r[0].Advisor__c, 'held by Hannah');
        Assert.areEqual(Date.newInstance(2026, 9, 20), code.Assignments__r[0].Effective_Start_Date__c, 'from the roster date');

        Code_Follow_Up__c fu = [SELECT Status__c, Rep_Code__c, Resolution_Notes__c, Held_Row_Count__c FROM Code_Follow_Up__c];
        Assert.areEqual('Resolved', fu.Status__c, 'follow-up resolved by the approval');
        Assert.areEqual(code.Id, fu.Rep_Code__c, 'linked to the new code');
        Assert.isTrue(fu.Resolution_Notes__c.contains('Hannah Pierce'), 'notes: ' + fu.Resolution_Notes__c);

        Import_Staging_Row__c trade = TradeTestWorld.row(trades.Id, 1);
        Assert.areEqual('Matched', trade.Match_Status__c, 'held trade matched after re-matching');
        Assert.areEqual(hannah.Id, trade.Credited_Advisor__c, 'credited to Hannah');
        Import_Staging_Row__c approved = TradeTestWorld.row(roster.Id, 1);
        Assert.areEqual('Matched', approved.Match_Status__c, 'roster row applied');
        Assert.areEqual('Reviewer', approved.Match_Method__c, 'applied by a reviewer');
    }

    @IsTest
    static void newHolderEndsTheOldAssignment() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c roster = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.roster('Barder & Company', '2210', 'Priya Nair', 'Barder & Company - Hamilton', Date.newInstance(2026, 9, 15)) }
        );
        Import_Staging_Row__c rosterRow = TradeTestWorld.row(roster.Id, 1);
        Assert.areEqual('NEW_ADVISOR;ROSTER_NEW_HOLDER', rosterRow.Match_Flags__c, 'new holder of an existing code');
        update new Import_Staging_Row__c(Id = rosterRow.Id, Reviewer_Decision__c = 'Accept');

        Rep_Code_Assignment__c marcus = [SELECT Effective_End_Date__c, End_Date_Source__c FROM Rep_Code_Assignment__c WHERE Advisor__c = :w.marcus.Id];
        Assert.areEqual(Date.newInstance(2026, 9, 14), marcus.Effective_End_Date__c, 'ended the day before');
        Assert.areEqual('Confirmed by Firm', marcus.End_Date_Source__c, 'source recorded');
        Rep_Code_Assignment__c priya = [SELECT Advisor__r.Name, Advisor__r.AccountId, Allocation_Percent__c FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :w.b2210.Id AND Effective_End_Date__c = NULL];
        Assert.areEqual('Priya Nair', priya.Advisor__r.Name, 'Priya holds the code');
        Assert.areEqual(w.barderHamilton.Id, priya.Advisor__r.AccountId, 'at Hamilton');
        Assert.areEqual(100, priya.Allocation_Percent__c.intValue(), 'full share');
    }

    @IsTest
    static void teamCodesAreLeftToAPerson() {
        TradeTestWorld w = TradeTestWorld.build();
        Rep_Code__c team = new Rep_Code__c(Name = '8800', Firm__c = w.barder.Id);
        insert team;
        insert new List<Rep_Code_Assignment__c>{
            new Rep_Code_Assignment__c(Rep_Code__c = team.Id, Advisor__c = w.julia.Id, Allocation_Percent__c = 50, Effective_Start_Date__c = Date.newInstance(2024, 1, 1)),
            new Rep_Code_Assignment__c(Rep_Code__c = team.Id, Advisor__c = w.marcus.Id, Allocation_Percent__c = 50, Effective_Start_Date__c = Date.newInstance(2024, 1, 1))
        };
        Import_Batch__c roster = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.roster('Barder & Company', '8800', 'Priya Nair', null, Date.newInstance(2026, 9, 15)) }
        );
        Database.SaveResult sr = Database.update(new Import_Staging_Row__c(Id = TradeTestWorld.row(roster.Id, 1).Id, Reviewer_Decision__c = 'Accept'), false);
        Assert.isFalse(sr.isSuccess(), 'refused');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('shared by a team'), 'error: ' + sr.getErrors()[0].getMessage());
        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE LastName = 'Nair'], 'nothing created');
        Assert.areEqual('Needs Review', TradeTestWorld.row(roster.Id, 1).Match_Status__c, 'row unchanged');
    }

    @IsTest
    static void rosterDateBeforeTheCurrentHolderIsRefused() {
        TradeTestWorld.build();
        Import_Batch__c roster = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.roster('Barder & Company', '2210', 'Priya Nair', null, Date.newInstance(2017, 1, 1)) }
        );
        Database.SaveResult sr = Database.update(new Import_Staging_Row__c(Id = TradeTestWorld.row(roster.Id, 1).Id, Reviewer_Decision__c = 'Accept'), false);
        Assert.isFalse(sr.isSuccess(), 'refused');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('not after the current holder'), 'error: ' + sr.getErrors()[0].getMessage());
    }

    @IsTest
    static void rosterRowWithUnknownFirmNeedsAFirmFirst() {
        TradeTestWorld.build();
        Import_Batch__c roster = matched(
            new List<Import_Staging_Row__c>{ TradeTestWorld.roster('Unheard Of Securities', '77', 'Sam Lee', null, Date.newInstance(2026, 9, 1)) }
        );
        Database.SaveResult sr = Database.update(new Import_Staging_Row__c(Id = TradeTestWorld.row(roster.Id, 1).Id, Reviewer_Decision__c = 'Accept'), false);
        Assert.isFalse(sr.isSuccess(), 'refused');
        Assert.isTrue(sr.getErrors()[0].getMessage().contains('Firm Override'), 'error: ' + sr.getErrors()[0].getMessage());
    }

    @IsTest
    static void newAdvisorNamesAreSplitSensibly() {
        Id firm = TradeTestWorld.build().barder.Id;
        Contact c = RosterApprovalService.newContact(
            new Import_Staging_Row__c(Source_Advisor_Name__c = '  Marc-André   St Pierre ', Source_Branch_Name__c = 'No Such Branch'),
            firm,
            new Map<String, Id>()
        );
        Assert.areEqual('Marc-André St', c.FirstName, 'everything but the last word');
        Assert.areEqual('Pierre', c.LastName, 'last word');
        Assert.areEqual(firm, c.AccountId, 'unknown branch falls back to the firm');
        Contact single = RosterApprovalService.newContact(new Import_Staging_Row__c(Source_Advisor_Name__c = 'Cher'), firm, new Map<String, Id>());
        Assert.isNull(single.FirstName, 'no first name');
        Assert.areEqual('Cher', single.LastName, 'single name');
    }
}
