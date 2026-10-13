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
}
