@IsTest
private class MatchingRuleTest {
    private static void twoPerson(Boolean required) {
        AiSettings s = new AiSettings();
        s.requireTwoPersonRuleApproval = required;
        AiSettings.current = s;
    }

    private static Matching_Rule__c proposed() {
        Matching_Rule__c r = new Matching_Rule__c(Name = 'ETF spelling', Rule__c = 'A leading ETF in a fund name means the Wealth World ETF.', Status__c = 'Proposed');
        insert r;
        return r;
    }

    private static String errorOf(Matching_Rule__c change) {
        Database.SaveResult sr = change.Id == null ? Database.insert(change, false) : Database.update(change, false);
        Assert.isFalse(sr.isSuccess(), 'the change should be refused');
        return sr.getErrors()[0].getMessage();
    }

    @IsTest
    static void authorCannotActivateTheirOwnRule() {
        twoPerson(true);
        Matching_Rule__c r = proposed();
        Assert.isTrue(errorOf(new Matching_Rule__c(Id = r.Id, Status__c = 'Active')).contains('Someone other than'), 'update refused');
        Assert.isTrue(errorOf(new Matching_Rule__c(Name = 'x', Rule__c = 'y', Status__c = 'Active')).contains('Someone other than'), 'insert as Active refused');
    }

    @IsTest
    static void anotherPersonActivatesAndIsRecorded() {
        twoPerson(true);
        Matching_Rule__c r = proposed();
        User approver = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Admin' });
        System.runAs(approver) {
            update new Matching_Rule__c(Id = r.Id, Status__c = 'Active');
        }
        r = [SELECT Status__c, Approved_By__c, Approved_At__c FROM Matching_Rule__c WHERE Id = :r.Id];
        Assert.areEqual('Active', r.Status__c, 'active');
        Assert.areEqual(approver.Id, r.Approved_By__c, 'approver recorded');
        Assert.isNotNull(r.Approved_At__c, 'time recorded');
    }

    @IsTest
    static void singlePersonModeStillRecordsTheApprover() {
        twoPerson(false);
        Matching_Rule__c r = proposed();
        update new Matching_Rule__c(Id = r.Id, Status__c = 'Active');
        Assert.areEqual(UserInfo.getUserId(), [SELECT Approved_By__c FROM Matching_Rule__c WHERE Id = :r.Id].Approved_By__c, 'approver recorded');
    }

    @IsTest
    static void activeRulesCannotBeEditedAndRetiringClearsApproval() {
        twoPerson(false);
        Matching_Rule__c r = proposed();
        update new Matching_Rule__c(Id = r.Id, Status__c = 'Active');
        Assert.isTrue(errorOf(new Matching_Rule__c(Id = r.Id, Rule__c = 'Something else.')).contains('cannot be edited'), 'edit refused');
        Assert.isTrue(errorOf(new Matching_Rule__c(Id = r.Id, Approved_By__c = null)).contains('set by the system'), 'approval cannot be hand-edited');
        update new Matching_Rule__c(Id = r.Id, Status__c = 'Retired');
        r = [SELECT Approved_By__c, Approved_At__c FROM Matching_Rule__c WHERE Id = :r.Id];
        Assert.isNull(r.Approved_By__c, 'approval cleared');
        Assert.isNull(r.Approved_At__c, 'approval time cleared');
        Assert.isTrue(errorOf(new Matching_Rule__c(Name = 'x', Rule__c = 'y', Approved_By__c = UserInfo.getUserId())).contains('set by the system'), 'cannot be set on insert');
    }
}
