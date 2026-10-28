@IsTest
private class MappingServiceTest {
    private static final List<String> HEADERS = new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Fund', 'Gross Amt', 'Notes' };

    private static Mapping_Profile__c profileWith(Map<String, String> columnMap, String convention) {
        return TestDataFactory.profile('BARDER', HEADERS, columnMap, 'MM/DD/YYYY', 'Period', convention);
    }

    private static Map<String, String> validMap() {
        return new Map<String, String>{
            'Trade Dt' => 'tradeDate',
            'Dealer Rep #' => 'repCode',
            'Fund' => 'fundName',
            'Gross Amt' => 'amount',
            'Notes' => 'IGNORE'
        };
    }

    private static String problemsFor(List<String> headers, Mapping_Profile__c profile) {
        try {
            MappingService.resolveColumns(headers, profile);
            return null;
        } catch (MappingService.MappingException e) {
            return e.getMessage();
        }
    }

    @IsTest
    static void headerKeyNormalizes() {
        Assert.areEqual('trade dt', MappingService.headerKey('  Trade   DT '), 'trim, lower-case, single spaces');
        Assert.areEqual('', MappingService.headerKey(null), 'null header');
    }

    @IsTest
    static void fingerprintIgnoresCaseAndSpacingButNotOrder() {
        String a = MappingService.fingerprint(new List<String>{ 'Trade Dt', 'Amount' });
        Assert.areEqual(a, MappingService.fingerprint(new List<String>{ ' trade  dt', 'AMOUNT ' }), 'case and spacing');
        Assert.areNotEqual(a, MappingService.fingerprint(new List<String>{ 'Amount', 'Trade Dt' }), 'order matters');
        Assert.areEqual(64, a.length(), 'SHA-256 hex length');
    }

    @IsTest
    static void resolvesValidMap() {
        List<String> cols = MappingService.resolveColumns(HEADERS, profileWith(validMap(), TestDataFactory.SIGNED));
        Assert.areEqual(new List<String>{ 'tradeDate', 'repCode', 'fundName', 'amount', 'IGNORE' }, cols, 'columns in file order');
    }

    @IsTest
    static void headerMatchingIsCaseInsensitive() {
        Map<String, String> m = validMap();
        m.remove('Trade Dt');
        m.put('TRADE DT', 'tradeDate');
        List<String> cols = MappingService.resolveColumns(HEADERS, profileWith(m, TestDataFactory.SIGNED));
        Assert.areEqual('tradeDate', cols[0], 'case-insensitive header lookup');
    }

    @IsTest
    static void reportsEveryProblemAtOnce() {
        Map<String, String> m = new Map<String, String>{ 'Trade Dt' => 'tradeDate', 'Dealer Rep #' => 'amount', 'Gross Amt' => 'amount' };
        String problems = problemsFor(HEADERS, profileWith(m, TestDataFactory.SIGNED));
        Assert.isTrue(problems.contains('Column "Fund" is not mapped'), 'problems: ' + problems);
        Assert.isTrue(problems.contains('Column "Notes" is not mapped'), 'problems: ' + problems);
        Assert.isTrue(problems.contains('More than one column is mapped to amount'), 'problems: ' + problems);
        Assert.isTrue(problems.contains('No column is mapped to repCode'), 'problems: ' + problems);
        Assert.isTrue(problems.contains('No column is mapped to fundName'), 'problems: ' + problems);
    }

    @IsTest
    static void enforcesDirectionConvention() {
        List<String> headers = new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Fund', 'Gross Amt', 'Side' };
        Map<String, String> withType = new Map<String, String>{
            'Trade Dt' => 'tradeDate',
            'Dealer Rep #' => 'repCode',
            'Fund' => 'fundName',
            'Gross Amt' => 'amount',
            'Side' => 'transactionType'
        };
        String signedProblems = problemsFor(headers, TestDataFactory.profile('X', headers, withType, 'MM/DD/YYYY', 'Period', TestDataFactory.SIGNED));
        Assert.isTrue(signedProblems.contains('must be mapped to IGNORE'), 'problems: ' + signedProblems);

        withType.put('Side', 'IGNORE');
        String typeProblems = problemsFor(headers, TestDataFactory.profile('X', headers, withType, 'MM/DD/YYYY', 'Period', TestDataFactory.TYPE_COLUMN));
        Assert.isTrue(typeProblems.contains('no column is mapped to transactionType'), 'problems: ' + typeProblems);
    }

    @IsTest
    static void rejectsBadColumnMaps() {
        Mapping_Profile__c p = profileWith(validMap(), TestDataFactory.SIGNED);
        p.Column_Map__c = null;
        Assert.isTrue(problemsFor(HEADERS, p).contains('no Column Map'), 'blank map');
        p.Column_Map__c = '{not json';
        Assert.isTrue(problemsFor(HEADERS, p).contains('not valid JSON'), 'invalid JSON');
        p.Column_Map__c = '["a"]';
        Assert.isTrue(problemsFor(HEADERS, p).contains('must be a JSON object'), 'array JSON');
        Map<String, String> m = validMap();
        m.put('Notes', 'comments');
        p.Column_Map__c = System.JSON.serialize(m);
        Assert.isTrue(problemsFor(HEADERS, p).contains('not a known field'), 'unknown canonical field');
    }

    @IsTest
    static void rejectsDuplicateHeaders() {
        List<String> headers = new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Fund', 'Gross Amt', 'fund' };
        Map<String, String> m = validMap();
        m.remove('Notes');
        String problems = problemsFor(headers, TestDataFactory.profile('X', headers, m, 'MM/DD/YYYY', 'Period', TestDataFactory.SIGNED));
        Assert.isTrue(problems.contains('more than one column named'), 'problems: ' + problems);
    }

    @IsTest
    static void findsActiveProfileByFingerprintAndFirm() {
        String fp = MappingService.fingerprint(HEADERS);
        Assert.isNull(MappingService.findActiveProfile(fp, 'BARDER'), 'none yet');

        Mapping_Profile__c draft = profileWith(validMap(), TestDataFactory.SIGNED);
        draft.Status__c = 'Draft';
        insert draft;
        Assert.isNull(MappingService.findActiveProfile(fp, 'BARDER'), 'drafts are ignored');

        Mapping_Profile__c barder = profileWith(validMap(), TestDataFactory.SIGNED);
        insert barder;
        Assert.areEqual(barder.Id, MappingService.findActiveProfile(fp, 'NORTHGATE')?.Id, 'single active profile is used for any firm');

        Mapping_Profile__c northgate = TestDataFactory.profile('NORTHGATE', HEADERS, validMap(), 'DD/MM/YYYY', 'Period', TestDataFactory.SIGNED);
        insert northgate;
        Assert.areEqual(northgate.Id, MappingService.findActiveProfile(fp, 'northgate').Id, 'firm breaks the tie, case-insensitive');

        insert TestDataFactory.profile('NORTHGATE', HEADERS, validMap(), 'DD/MM/YYYY', 'Period', TestDataFactory.SIGNED);
        try {
            MappingService.findActiveProfile(fp, 'NORTHGATE');
            Assert.fail('Expected MappingException for two active profiles for one firm');
        } catch (MappingService.MappingException e) {
            Assert.isTrue(e.getMessage().contains('More than one Active mapping profile'), 'message: ' + e.getMessage());
        }
    }

    // ------------------------------------------------------------------ phase 3A: feed types and AUM settings

    @IsTest
    static void rosterProfilesNeedCodeAdvisorAndDateButNoDirection() {
        List<String> headers = new List<String>{ 'Rep Code', 'Advisor Name', 'Branch', 'Effective Date' };
        Mapping_Profile__c p = TestDataFactory.profile(
            'BARDER',
            headers,
            new Map<String, String>{ 'Rep Code' => 'repCode', 'Advisor Name' => 'advisorName', 'Branch' => 'branchName', 'Effective Date' => 'tradeDate' },
            'MM/DD/YYYY',
            'Period',
            TestDataFactory.TYPE_COLUMN
        );
        p.Feed_Type__c = MappingService.FEED_ROSTER;
        Assert.areEqual(
            new List<String>{ 'repCode', 'advisorName', 'branchName', 'tradeDate' },
            MappingService.resolveColumns(headers, p),
            'roster columns resolve without fund, amount or transaction type'
        );
        p.Column_Map__c = System.JSON.serialize(
            new Map<String, String>{ 'Rep Code' => 'repCode', 'Advisor Name' => 'IGNORE', 'Branch' => 'branchName', 'Effective Date' => 'tradeDate' }
        );
        String problems = problemsFor(headers, p);
        Assert.isTrue(problems.contains('No column is mapped to advisorName'), 'problems: ' + problems);
    }

    @IsTest
    static void aumSettingsMustBeConsistent() {
        List<String> headers = new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Fund', 'Gross Amt', 'Record Type' };
        Map<String, String> m = new Map<String, String>{
            'Trade Dt' => 'tradeDate',
            'Dealer Rep #' => 'repCode',
            'Fund' => 'fundName',
            'Gross Amt' => 'amount',
            'Record Type' => 'rowType'
        };
        Mapping_Profile__c p = TestDataFactory.profile('BARDER', headers, m, 'MM/DD/YYYY', 'Period', TestDataFactory.SIGNED);
        String noIndicators = problemsFor(headers, p);
        Assert.isTrue(noIndicators.contains('AUM Indicator Values must list'), 'problems: ' + noIndicators);
        p.AUM_Indicator_Values__c = 'AUM';
        Assert.areEqual(5, MappingService.resolveColumns(headers, p).size(), 'valid once indicators are set');

        m.put('Record Type', 'IGNORE');
        p.Column_Map__c = System.JSON.serialize(m);
        String nowhere = problemsFor(headers, p);
        Assert.isTrue(nowhere.contains('no rowType or transactionType column'), 'problems: ' + nowhere);
    }

    @IsTest
    static void findActiveProfileReturnsFeedSettings() {
        Mapping_Profile__c p = profileWith(validMap(), TestDataFactory.SIGNED);
        p.Feed_Type__c = MappingService.FEED_TRADE_ACTIVITY;
        p.AUM_Indicator_Values__c = 'AUM';
        insert p;
        Mapping_Profile__c found = MappingService.findActiveProfile(MappingService.fingerprint(HEADERS), 'BARDER');
        Assert.areEqual('AUM', found.AUM_Indicator_Values__c, 'indicators selected');
        Assert.areEqual(MappingService.FEED_TRADE_ACTIVITY, found.Feed_Type__c, 'feed type selected');
        Assert.isFalse(MappingService.isRoster(found), 'not a roster');
    }
}
