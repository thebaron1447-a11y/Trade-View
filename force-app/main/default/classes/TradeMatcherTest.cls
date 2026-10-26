// Edge cases not reached by DemoScenarioTest. Expected outcomes were computed with the Python port first.
@IsTest
private class TradeMatcherTest {
    @TestSetup
    static void setup() {
        Account alder = new Account(Name = 'Alder Securities Inc.');
        Account kesInc = new Account(Name = 'Kestrel Capital Inc.');
        Account kesLtd = new Account(Name = 'Kestrel Capital Ltd.');
        insert new List<Account>{ alder, kesInc, kesLtd };
        Contact zoe = new Contact(FirstName = 'Zoe', LastName = 'Park', AccountId = alder.Id);
        insert new List<Contact>{
            zoe,
            new Contact(FirstName = 'Sam', LastName = 'Lee', AccountId = alder.Id),
            new Contact(FirstName = 'Sara', LastName = 'Lee', AccountId = alder.Id)
        };
        Product2 bond = new Product2(Name = 'Global Bond Fund - Series F', IsActive = true);
        insert bond;
        insert new List<SObject>{
            new Firm_Alias__c(Name = 'Alder Securities Inc.', Normalized_Key__c = 'alder securities', Firm__c = alder.Id),
            new Firm_Alias__c(Name = 'Kestrel Capital Inc.', Normalized_Key__c = 'kestrel capital', Firm__c = kesInc.Id),
            new Firm_Alias__c(Name = 'Kestrel Capital Ltd.', Normalized_Key__c = 'kestrel capital', Firm__c = kesLtd.Id),
            new Fund_Alias__c(Name = 'Global Bond Fund - Series F', Normalized_Key__c = 'global bond fund series f', Fund__c = bond.Id)
        };
        Rep_Code__c code = new Rep_Code__c(Name = '100', Firm__c = alder.Id);
        insert code;
        insert new Rep_Code_Assignment__c(Rep_Code__c = code.Id, Advisor__c = zoe.Id, Allocation_Percent__c = 100, Effective_Start_Date__c = Date.newInstance(2026, 1, 1));
    }

    private static Import_Staging_Row__c row(String firm, String advisor, String fund, Date d, String rowType) {
        return new Import_Staging_Row__c(
            Source_Firm_Name__c = firm,
            Source_Rep_Code__c = '100',
            Source_Advisor_Name__c = advisor,
            Source_Fund_Name__c = fund,
            Trade_Date__c = d,
            Row_Type__c = rowType,
            Amount__c = 1000
        );
    }

    private static TradeMatcher.Outcome match(Import_Staging_Row__c r) {
        TradeMatcher.Reference ref = new TradeMatcher.Reference(new List<Import_Staging_Row__c>{ r });
        return r.Row_Type__c == 'Code Roster' ? TradeMatcher.matchRoster(r, ref) : TradeMatcher.matchActivity(r, ref);
    }

    private static final Date JUNE = Date.newInstance(2026, 6, 1);
    private static final String FUND = 'Global Bond Fund - Series F';

    @IsTest
    static void missingUnresolvedAndAmbiguousFirmsGoToReview() {
        TradeMatcher.Outcome missing = match(row(null, 'Zoe Park', FUND, JUNE, 'Trade'));
        Assert.areEqual('Needs Review', missing.status, 'missing firm');
        Assert.areEqual(new List<String>{ 'FIRM_MISSING' }, missing.flags, 'missing flags');

        TradeMatcher.Outcome unknown = match(row('Zebra Partners', 'Zoe Park', FUND, JUNE, 'Trade'));
        Assert.areEqual('Needs Review', unknown.status, 'unresolved firm');
        Assert.areEqual(new List<String>{ 'FIRM_UNRESOLVED' }, unknown.flags, 'unresolved flags');
        Assert.isFalse(unknown.candidates.isEmpty(), 'closest firms offered as candidates');
        Assert.areEqual('firm', unknown.candidates[0].get('type'), 'candidate type');

        TradeMatcher.Outcome twoFirms = match(row('Kestrel Capital', 'Ryan Chen', FUND, JUNE, 'Trade'));
        Assert.areEqual('Needs Review', twoFirms.status, 'ambiguous firm');
        Assert.areEqual(new List<String>{ 'FIRM_AMBIGUOUS' }, twoFirms.flags, 'ambiguous flags');
        Assert.areEqual(2, twoFirms.candidates.size(), 'both Kestrel firms offered');
    }

    @IsTest
    static void closeSpellingsAreAcceptedAsFuzzyMatches() {
        TradeMatcher.Outcome firm = match(row('Alder Securitie', 'Zoe Park', FUND, JUNE, 'Trade'));
        Assert.areEqual('Matched', firm.status, 'fuzzy firm; flags ' + firm.flags);
        Assert.areEqual('Fuzzy', firm.method, 'method');
        Assert.areEqual(new List<String>{ 'FIRM_FUZZY' }, firm.flags, 'firm flags');

        TradeMatcher.Outcome fund = match(row('Alder Securities Inc.', 'Zoe Park', 'Global Bond Fund - Serie F', JUNE, 'Trade'));
        Assert.areEqual('Matched', fund.status, 'fuzzy fund; flags ' + fund.flags);
        Assert.areEqual(new List<String>{ 'FUND_FUZZY' }, fund.flags, 'fund flags');
        Assert.areEqual([SELECT Id FROM Product2 LIMIT 1].Id, fund.fundId, 'fund resolved');
        Assert.areEqual([SELECT Id FROM Contact WHERE LastName = 'Park'].Id, fund.creditedAdvisorId, 'solo code credits its holder');
    }

    @IsTest
    static void rowDatedBeforeTheCodeStartedGoesToReview() {
        TradeMatcher.Outcome early = match(row('Alder Securities Inc.', 'Zoe Park', FUND, Date.newInstance(2025, 6, 1), 'Trade'));
        Assert.areEqual('Needs Review', early.status, 'before start');
        Assert.areEqual(new List<String>{ 'DATE_BEFORE_CODE_START' }, early.flags, 'flags');
    }

    @IsTest
    static void rosterNameMatchingTwoAdvisorsIsFlagged() {
        TradeMatcher.Outcome o = match(row('Alder Securities Inc.', 'S. Lee', null, JUNE, 'Code Roster'));
        Assert.areEqual('Needs Review', o.status, 'roster');
        Assert.areEqual(new List<String>{ 'ADVISOR_AMBIGUOUS', 'ROSTER_NEW_HOLDER' }, o.flags, 'flags');
        Assert.isNull(o.creditedAdvisorId, 'no advisor chosen when two could fit');
    }

    @IsTest
    static void runSkipsBatchesThatAreNotReady() {
        Import_Batch__c batch = new Import_Batch__c(Source_Firm__c = 'ALDER', File_Hash__c = 'x', Status__c = 'Mapping Review');
        insert batch;
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Mapping Review', [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c, 'untouched');
    }

    @IsTest
    static void queuedJobRunsTheMatcher() {
        Import_Batch__c batch = new Import_Batch__c(Source_Firm__c = 'ALDER', File_Hash__c = 'y', Status__c = 'Staged');
        insert batch;
        insert new Import_Staging_Row__c(
            Import_Batch__c = batch.Id,
            Row_Number__c = 1,
            Row_Type__c = 'Trade',
            Source_Firm_Name__c = 'Alder Securities Inc.',
            Source_Rep_Code__c = '100',
            Source_Advisor_Name__c = 'Zoe Park',
            Source_Fund_Name__c = FUND,
            Trade_Date__c = JUNE,
            Amount__c = 500,
            Match_Status__c = 'Pending'
        );
        Test.startTest();
        System.enqueueJob(new TradeMatcher(new Set<Id>{ batch.Id }));
        Test.stopTest();
        Import_Batch__c after = [SELECT Status__c, Matched_Row_Count__c FROM Import_Batch__c WHERE Id = :batch.Id];
        Assert.areEqual('Pending Review', after.Status__c, 'batch ready for review');
        Assert.areEqual(1, after.Matched_Row_Count__c.intValue(), 'row matched');
    }

    private static String keyOf(String dealer, String rowType, String status, String flags, String firm, String fund, String code) {
        TradeMatcher.Outcome o = new TradeMatcher.Outcome();
        o.status = status;
        o.flags.addAll(flags.split(';'));
        Import_Staging_Row__c r = new Import_Staging_Row__c(Row_Type__c = rowType, Source_Firm_Name__c = firm, Source_Fund_Name__c = fund, Source_Rep_Code__c = code);
        return TradeMatcher.issueKey(dealer, r, o);
    }

    @IsTest
    static void rowsWithTheSameProblemShareAnIssueKey() {
        String a = keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED', 'Barder & Company', 'ETF Wealth World Fund A', '457');
        Assert.isNotNull(a, 'a review row with a fund spelling problem has a key');
        Assert.areEqual(a, keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED', 'Barder & Co', '  etf wealth world fund a ', '2210'), 'same spelling, any code or firm spelling: same issue');
        Assert.areNotEqual(a, keyOf('NORTHGATE', 'Trade', 'Needs Review', 'FUND_UNRESOLVED', 'Barder & Company', 'ETF Wealth World Fund A', '457'), 'another dealer is another issue');
        Assert.areNotEqual(
            keyOf('KESTREL', 'Trade', 'Needs Review', 'FIRM_AMBIGUOUS', 'Kestrel Capital', 'Wealth World ETF', '1001'),
            keyOf('KESTREL', 'Trade', 'Needs Review', 'FIRM_AMBIGUOUS', 'Kestrel Capital', 'Wealth World ETF', '2002'),
            'an ambiguous firm can be a different firm for each code'
        );
        Assert.areNotEqual(
            a,
            keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED;FIRM_UNRESOLVED', 'Bardr', 'ETF Wealth World Fund A', '457'),
            'a second issue makes a different group'
        );
        Assert.areEqual(
            keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED;FUND_FUZZY', 'Barder & Company', 'ETF Wealth World Fund A', '457'),
            a,
            'informational flags do not split a group'
        );
        Assert.isNull(keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED;DATE_BEFORE_CODE_START', 'Barder', 'X', '457'), 'code issues are decided one by one');
        Assert.isNull(keyOf('BARDER', 'Code Roster', 'Needs Review', 'ROSTER_NEW_CODE', 'Barder', null, '3390'), 'roster rows are decided one by one');
        Assert.isNull(keyOf('BARDER', 'Trade', 'Matched', 'FUND_FUZZY', 'Barder', 'X', '457'), 'only rows waiting for review');
        String longKey = keyOf('BARDER', 'Trade', 'Needs Review', 'FUND_UNRESOLVED', 'Barder', 'Fund '.repeat(80), '457');
        Assert.isTrue(longKey.startsWith('H:') && longKey.length() == 66, 'a long key is hashed: ' + longKey);
    }
}
