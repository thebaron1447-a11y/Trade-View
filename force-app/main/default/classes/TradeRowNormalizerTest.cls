@IsTest
private class TradeRowNormalizerTest {
    private static final List<String> HEADERS = new List<String>{ 'Date', 'Rep', 'Advisor', 'Firm', 'Fund', 'Side', 'Amount' };
    private static final List<String> COLUMNS = new List<String>{
        'tradeDate', 'repCode', 'advisorName', 'firmName', 'fundName', 'transactionType', 'amount'
    };
    private static final List<String> SIGNED_COLUMNS = new List<String>{
        'tradeDate', 'repCode', 'advisorName', 'firmName', 'fundName', 'IGNORE', 'amount'
    };

    private static TradeRowNormalizer.Config config(String convention) {
        TradeRowNormalizer.Config cfg = new TradeRowNormalizer.Config();
        cfg.dateFormat = 'MM/DD/YYYY';
        cfg.decimalSeparator = 'Period';
        cfg.directionConvention = convention;
        return cfg;
    }

    private static Import_Staging_Row__c run(List<String> values, List<String> columns, TradeRowNormalizer.Config cfg) {
        return TradeRowNormalizer.normalize(HEADERS, values, columns, cfg, 7);
    }

    @IsTest
    static void normalizesTypeColumnRow() {
        Import_Staging_Row__c row = run(
            new List<String>{ '09/13/2026', '0457', '  Julia   Morales ', 'Barder and Co', 'Wealth World Fund A', 'BUY', '$400,000.00' },
            COLUMNS,
            config(TestDataFactory.TYPE_COLUMN)
        );
        Assert.isFalse(row.Has_Errors__c, 'errors: ' + row.Validation_Errors__c);
        Assert.areEqual(7, row.Row_Number__c.intValue(), 'row number');
        Assert.areEqual('457', row.Source_Rep_Code__c, 'leading zero removed');
        Assert.areEqual('Julia Morales', row.Source_Advisor_Name__c, 'spaces collapsed');
        Assert.areEqual('Barder and Co', row.Source_Firm_Name__c, 'firm');
        Assert.areEqual(Date.newInstance(2026, 9, 13), row.Trade_Date__c, 'date');
        Assert.areEqual('Purchase', row.Transaction_Type__c, 'type');
        Assert.areEqual(400000.00, row.Amount__c, 'amount');
        Map<String, Object> raw = (Map<String, Object>) System.JSON.deserializeUntyped(row.Raw_Data__c);
        Assert.areEqual('0457', raw.get('Rep'), 'raw value kept as received');
    }

    @IsTest
    static void signedAmountSetsDirection() {
        TradeRowNormalizer.Config cfg = config(TestDataFactory.SIGNED);
        Import_Staging_Row__c sell = run(new List<String>{ '09/13/2026', '2210', '', '', 'Fund', '', '-$150,000' }, SIGNED_COLUMNS, cfg);
        Assert.isFalse(sell.Has_Errors__c, 'errors: ' + sell.Validation_Errors__c);
        Assert.areEqual('Redemption', sell.Transaction_Type__c, 'negative is a redemption');
        Assert.areEqual(150000.00, sell.Amount__c, 'stored positive');
        Import_Staging_Row__c buy = run(new List<String>{ '09/13/2026', '2210', '', '', 'Fund', '', '150000' }, SIGNED_COLUMNS, cfg);
        Assert.areEqual('Purchase', buy.Transaction_Type__c, 'positive is a purchase');
    }

    @IsTest
    static void typeColumnRejectsNegativeAndUnknownTypes() {
        TradeRowNormalizer.Config cfg = config(TestDataFactory.TYPE_COLUMN);
        Import_Staging_Row__c negative = run(new List<String>{ '09/13/2026', '1', '', '', 'Fund', 'SELL', '-100' }, COLUMNS, cfg);
        Assert.isTrue(negative.Has_Errors__c, 'negative amount with a type column');
        Assert.isTrue(negative.Validation_Errors__c.contains('Amount is negative'), 'errors: ' + negative.Validation_Errors__c);
        Assert.areEqual('Redemption', negative.Transaction_Type__c, 'type still recorded');
        Assert.isNull(negative.Amount__c, 'amount not stored');

        Import_Staging_Row__c unknown = run(new List<String>{ '09/13/2026', '1', '', '', 'Fund', 'SWITCH', '100' }, COLUMNS, cfg);
        Assert.isTrue(unknown.Validation_Errors__c.contains('"SWITCH" is not recognized'), 'errors: ' + unknown.Validation_Errors__c);
    }

    @IsTest
    static void reportsMissingRequiredValues() {
        Import_Staging_Row__c row = run(new List<String>{ '', ' ', '', '', '', 'BUY', '' }, COLUMNS, config(TestDataFactory.TYPE_COLUMN));
        Assert.isTrue(row.Has_Errors__c, 'errors expected');
        for (String expected : new List<String>{ 'Rep code is missing', 'Fund name is missing', 'Trade date is missing', 'Amount is missing' }) {
            Assert.isTrue(row.Validation_Errors__c.contains(expected), expected + ' in ' + row.Validation_Errors__c);
        }
    }

    @IsTest
    static void reportsZeroAndTooLongValues() {
        Import_Staging_Row__c row = run(
            new List<String>{ '09/13/2026', '1'.repeat(41), '', '', 'Fund', 'BUY', '0.00' },
            COLUMNS,
            config(TestDataFactory.TYPE_COLUMN)
        );
        Assert.isTrue(row.Validation_Errors__c.contains('Amount is zero'), 'errors: ' + row.Validation_Errors__c);
        Assert.isTrue(row.Validation_Errors__c.contains('Rep code is longer than 40'), 'errors: ' + row.Validation_Errors__c);
        Assert.areEqual(40, row.Source_Rep_Code__c.length(), 'truncated to field length');
    }

    @IsTest
    static void flagsColumnCountMismatch() {
        Import_Staging_Row__c row = run(new List<String>{ '09/13/2026', '457', 'Julia', 'Barder' }, COLUMNS, config(TestDataFactory.TYPE_COLUMN));
        Assert.isTrue(row.Validation_Errors__c.contains('Row has 4 values but the header has 7 columns'), 'errors: ' + row.Validation_Errors__c);
        Assert.isTrue(row.Raw_Data__c.startsWith('['), 'raw kept as a JSON array when columns do not line up');
    }

    @IsTest
    static void singleFirmFeedFillsMissingFirmOnly() {
        TradeRowNormalizer.Config cfg = config(TestDataFactory.TYPE_COLUMN);
        cfg.fallbackFirmName = 'Northgate Wealth Partners Inc.';
        Import_Staging_Row__c blank = run(new List<String>{ '09/13/2026', '8800', '', '', 'Fund', 'BUY', '10' }, COLUMNS, cfg);
        Assert.areEqual('Northgate Wealth Partners Inc.', blank.Source_Firm_Name__c, 'filled from profile');
        Import_Staging_Row__c given = run(new List<String>{ '09/13/2026', '8800', '', 'Northgate WP', 'Fund', 'BUY', '10' }, COLUMNS, cfg);
        Assert.areEqual('Northgate WP', given.Source_Firm_Name__c, 'file value wins');
    }

    @IsTest
    static void configFromProfile() {
        Account firm = TestDataFactory.firm('Northgate Wealth Partners Inc.');
        Mapping_Profile__c p = new Mapping_Profile__c(
            Date_Format__c = 'DD/MM/YYYY',
            Decimal_Separator__c = 'Comma',
            Direction_Convention__c = TestDataFactory.TYPE_COLUMN,
            Single_Firm_Feed__c = true,
            Firm__c = firm.Id
        );
        p.Firm__r = firm;
        TradeRowNormalizer.Config cfg = TradeRowNormalizer.configFrom(p);
        Assert.areEqual('DD/MM/YYYY', cfg.dateFormat, 'date format');
        Assert.areEqual('Comma', cfg.decimalSeparator, 'separator');
        Assert.areEqual('Northgate Wealth Partners Inc.', cfg.fallbackFirmName, 'fallback firm');
        p.Single_Firm_Feed__c = false;
        Assert.isNull(TradeRowNormalizer.configFrom(p).fallbackFirmName, 'no fallback when not a single-firm feed');
    }

    @IsTest
    static void invalidProfileSettingsAreReported() {
        TradeRowNormalizer.Config cfg = config(null);
        cfg.dateFormat = 'DD-MON-YY';
        Import_Staging_Row__c row = run(new List<String>{ '13-SEP-26', '1', '', '', 'Fund', 'BUY', '10' }, COLUMNS, cfg);
        Assert.isTrue(row.Validation_Errors__c.contains('no valid Date Format'), 'errors: ' + row.Validation_Errors__c);
        Assert.isTrue(row.Validation_Errors__c.contains('no valid Direction Convention'), 'errors: ' + row.Validation_Errors__c);
    }

    // ------------------------------------------------------------------ phase 3A: AUM, roster, branch

    private static final List<String> MIXED_HEADERS = new List<String>{ 'Date', 'Rep', 'Advisor', 'Branch', 'Fund', 'Side', 'Amount' };
    private static final List<String> MIXED_COLUMNS = new List<String>{
        'tradeDate', 'repCode', 'advisorName', 'branchName', 'fundName', 'transactionType', 'amount'
    };

    private static TradeRowNormalizer.Config aumConfig() {
        TradeRowNormalizer.Config cfg = config(TestDataFactory.TYPE_COLUMN);
        cfg.aumIndicators = new Set<String>{ 'POSITION', 'AUM' };
        return cfg;
    }

    private static Import_Staging_Row__c mixed(List<String> values, TradeRowNormalizer.Config cfg) {
        return TradeRowNormalizer.normalize(MIXED_HEADERS, values, MIXED_COLUMNS, cfg, 1);
    }

    @IsTest
    static void aumRowsAreRecognizedFromTheTypeColumn() {
        Import_Staging_Row__c aum = mixed(new List<String>{ '09/30/2026', '5521', 'Tom Reilly', 'Toronto', '', 'Position', '640,000' }, aumConfig());
        Assert.isFalse(aum.Has_Errors__c, 'errors: ' + aum.Validation_Errors__c);
        Assert.areEqual('AUM', aum.Row_Type__c, 'row type');
        Assert.areEqual(640000.00, aum.Amount__c, 'balance');
        Assert.isNull(aum.Transaction_Type__c, 'AUM has no direction');
        Assert.isNull(aum.Source_Fund_Name__c, 'fund optional for AUM');
        Assert.areEqual('Toronto', aum.Source_Branch_Name__c, 'branch captured');
        Assert.areEqual('Pending', aum.Match_Status__c, 'ready for matching');

        Import_Staging_Row__c zero = mixed(new List<String>{ '09/30/2026', '5521', '', '', '', 'AUM', '0' }, aumConfig());
        Assert.isFalse(zero.Has_Errors__c, 'zero AUM is valid: ' + zero.Validation_Errors__c);

        Import_Staging_Row__c negative = mixed(new List<String>{ '09/30/2026', '5521', '', '', '', 'AUM', '-5' }, aumConfig());
        Assert.isTrue(negative.Validation_Errors__c.contains('AUM value is negative'), 'errors: ' + negative.Validation_Errors__c);
        Assert.areEqual('Invalid', negative.Match_Status__c, 'invalid rows are never matched');

        Import_Staging_Row__c missing = mixed(new List<String>{ '', '5521', '', '', '', 'AUM', '' }, aumConfig());
        Assert.isTrue(missing.Validation_Errors__c.contains('As-of date is missing'), 'errors: ' + missing.Validation_Errors__c);
        Assert.isTrue(missing.Validation_Errors__c.contains('AUM value is missing'), 'errors: ' + missing.Validation_Errors__c);

        Import_Staging_Row__c trade = mixed(new List<String>{ '09/30/2026', '5521', 'Tom Reilly', 'Toronto', 'Fund', 'BUY', '100' }, aumConfig());
        Assert.areEqual('Trade', trade.Row_Type__c, 'non-indicator values stay trades');
        Assert.areEqual('Purchase', trade.Transaction_Type__c, 'direction still applies');
    }

    @IsTest
    static void aumRowsAreRecognizedFromARowTypeColumn() {
        List<String> headers = new List<String>{ 'Date', 'Rep', 'Fund', 'Record', 'Amount' };
        List<String> columns = new List<String>{ 'tradeDate', 'repCode', 'fundName', 'rowType', 'amount' };
        TradeRowNormalizer.Config cfg = config(TestDataFactory.SIGNED);
        cfg.aumIndicators = new Set<String>{ 'AUM' };
        Import_Staging_Row__c aum = TradeRowNormalizer.normalize(headers, new List<String>{ '09/30/2026', '457', '', 'aum', '$1,850,000.00' }, columns, cfg, 1);
        Assert.areEqual('AUM', aum.Row_Type__c, 'row type column, case-insensitive');
        Assert.areEqual(1850000.00, aum.Amount__c, 'balance');
        Import_Staging_Row__c trade = TradeRowNormalizer.normalize(headers, new List<String>{ '09/30/2026', '457', 'Fund', 'TRADE', '-$100' }, columns, cfg, 2);
        Assert.areEqual('Trade', trade.Row_Type__c, 'trade row');
        Assert.areEqual('Redemption', trade.Transaction_Type__c, 'signed amount still sets direction');
    }

    @IsTest
    static void rosterRowsNeedCodeAdvisorAndEffectiveDate() {
        List<String> headers = new List<String>{ 'Rep Code', 'Advisor Name', 'Branch', 'Effective Date' };
        List<String> columns = new List<String>{ 'repCode', 'advisorName', 'branchName', 'tradeDate' };
        TradeRowNormalizer.Config cfg = config(TestDataFactory.TYPE_COLUMN);
        cfg.roster = true;
        Import_Staging_Row__c ok = TradeRowNormalizer.normalize(headers, new List<String>{ '2210', 'Priya Nair', 'Hamilton', '09/15/2026' }, columns, cfg, 1);
        Assert.isFalse(ok.Has_Errors__c, 'errors: ' + ok.Validation_Errors__c);
        Assert.areEqual('Code Roster', ok.Row_Type__c, 'row type');
        Assert.areEqual(Date.newInstance(2026, 9, 15), ok.Trade_Date__c, 'effective date');
        Assert.isNull(ok.Amount__c, 'no amount on roster rows');
        Import_Staging_Row__c bad = TradeRowNormalizer.normalize(headers, new List<String>{ '2210', '', 'Hamilton', '' }, columns, cfg, 2);
        Assert.isTrue(bad.Validation_Errors__c.contains('Advisor name is missing'), 'errors: ' + bad.Validation_Errors__c);
        Assert.isTrue(bad.Validation_Errors__c.contains('Effective date is missing'), 'errors: ' + bad.Validation_Errors__c);
    }

    @IsTest
    static void configReadsFeedTypeAndIndicators() {
        Mapping_Profile__c p = new Mapping_Profile__c(
            Date_Format__c = 'MM/DD/YYYY',
            Decimal_Separator__c = 'Period',
            Direction_Convention__c = TestDataFactory.TYPE_COLUMN,
            AUM_Indicator_Values__c = ' Position, bal ,, AUM-Total'
        );
        TradeRowNormalizer.Config cfg = TradeRowNormalizer.configFrom(p);
        Assert.areEqual(new Set<String>{ 'POSITION', 'BAL', 'AUMTOTAL' }, cfg.aumIndicators, 'normalized indicators');
        Assert.isFalse(cfg.roster, 'blank feed type is Trade Activity');
        p.Feed_Type__c = MappingService.FEED_ROSTER;
        Assert.isTrue(TradeRowNormalizer.configFrom(p).roster, 'roster feed');
    }
}
