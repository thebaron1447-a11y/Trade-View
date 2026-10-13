@IsTest
private class ImportBatchProcessorTest {
    private static final List<String> HEADERS = new List<String>{ 'Trade Dt', 'Dealer Rep #', 'Advisor', 'Dealer Name', 'Fund Description', 'Gross Amt' };

    private static Mapping_Profile__c barderProfile(Id firmId) {
        Mapping_Profile__c p = TestDataFactory.profile(
            'BARDER',
            HEADERS,
            new Map<String, String>{
                'Trade Dt' => 'tradeDate',
                'Dealer Rep #' => 'repCode',
                'Advisor' => 'advisorName',
                'Dealer Name' => 'firmName',
                'Fund Description' => 'fundName',
                'Gross Amt' => 'amount'
            },
            'MM/DD/YYYY',
            'Period',
            TestDataFactory.SIGNED
        );
        p.Single_Firm_Feed__c = true;
        p.Firm__c = firmId;
        insert p;
        return p;
    }

    private static String csv(List<String> rows) {
        return String.join(HEADERS, ',') + '\r\n' + String.join(rows, '\r\n') + '\r\n';
    }

    /** Creates the batch as the integration user and runs the job, exactly as the endpoint would. */
    private static Import_Batch__c runAsIntegration(String content) {
        return runAsIntegration(TestDataFactory.integrationUser(), content);
    }

    private static Import_Batch__c runAsIntegration(User integration, String content) {
        Import_Batch__c batch;
        System.runAs(integration) {
            batch = TestDataFactory.receivedBatch('BARDER', content);
            Test.startTest();
            System.enqueueJob(new ImportBatchProcessor(batch.Id));
            Test.stopTest();
        }
        return [
            SELECT Id, Status__c, Row_Count__c, Error_Row_Count__c, Error_Message__c, Mapping_Profile__c
            FROM Import_Batch__c
            WHERE Id = :batch.Id
        ];
    }

    private static List<Import_Staging_Row__c> rowsFor(Id batchId) {
        return [
            SELECT Row_Number__c, Source_Rep_Code__c, Source_Firm_Name__c, Source_Fund_Name__c, Trade_Date__c,
                Transaction_Type__c, Amount__c, Has_Errors__c, Validation_Errors__c
            FROM Import_Staging_Row__c
            WHERE Import_Batch__c = :batchId
            ORDER BY Row_Number__c
        ];
    }

    @IsTest
    static void stagesEveryRowIncludingRowsWithErrors() {
        User integration = TestDataFactory.integrationUser();
        Account firm;
        // Created by the integration user so the test does not depend on the org's Account sharing defaults.
        System.runAs(integration) {
            firm = TestDataFactory.firm('Barder & Company');
        }
        Mapping_Profile__c profile = barderProfile(firm.Id);
        Import_Batch__c batch = runAsIntegration(
            integration,
            csv(new List<String>{
                '09/13/2026,0457,Julia Morales,Barder and Co,Wealth World Fund A,"$400,000.00"',
                '09/14/2026,2210,Marcus Bell,,Wealth World ETF,"-$150,000.00"',
                '13/09/2026,2210,Marcus Bell,Barder and C.,Wealth World ETF,"$5,000.00"'
            })
        );
        Assert.areEqual(ImportBatchProcessor.STATUS_STAGED, batch.Status__c, 'error message: ' + batch.Error_Message__c);
        Assert.areEqual(3, batch.Row_Count__c.intValue(), 'row count');
        Assert.areEqual(1, batch.Error_Row_Count__c.intValue(), 'one row has an invalid date for MM/DD/YYYY');
        Assert.areEqual(profile.Id, batch.Mapping_Profile__c, 'profile recorded');

        List<Import_Staging_Row__c> rows = rowsFor(batch.Id);
        Assert.areEqual(3, rows.size(), 'every row staged');
        Assert.areEqual('457', rows[0].Source_Rep_Code__c, 'normalized code');
        Assert.areEqual('Purchase', rows[0].Transaction_Type__c, 'purchase');
        Assert.areEqual(400000.00, rows[0].Amount__c, 'amount');
        Assert.areEqual('Redemption', rows[1].Transaction_Type__c, 'negative amount is a redemption');
        Assert.areEqual(150000.00, rows[1].Amount__c, 'stored positive');
        Assert.areEqual('Barder & Company', rows[1].Source_Firm_Name__c, 'single-firm feed fills the blank firm');
        Assert.isTrue(rows[2].Has_Errors__c, 'invalid date flagged');
        Assert.isTrue(rows[2].Validation_Errors__c.contains('13/09/2026'), 'errors: ' + rows[2].Validation_Errors__c);
    }

    @IsTest
    static void unknownLayoutStopsAtMappingReview() {
        Import_Batch__c batch = runAsIntegration('Representative,Rep No.,Value\r\nRyan Chen,1001,100\r\n');
        Assert.areEqual(ImportBatchProcessor.STATUS_MAPPING_REVIEW, batch.Status__c, 'no profile for this layout');
        Assert.areEqual(1, batch.Row_Count__c.intValue(), 'rows counted');
        Assert.isNull(batch.Mapping_Profile__c, 'no profile');
        Assert.isTrue(rowsFor(batch.Id).isEmpty(), 'nothing staged');
    }

    @IsTest
    static void incompleteProfileStopsAtMappingReviewWithReasons() {
        Mapping_Profile__c p = TestDataFactory.profile(
            'BARDER', HEADERS, new Map<String, String>{ 'Trade Dt' => 'tradeDate' }, 'MM/DD/YYYY', 'Period', TestDataFactory.SIGNED
        );
        insert p;
        Import_Batch__c batch = runAsIntegration(csv(new List<String>{ '09/13/2026,457,Julia,Barder,Fund,100' }));
        Assert.areEqual(ImportBatchProcessor.STATUS_MAPPING_REVIEW, batch.Status__c, 'incomplete profile');
        Assert.areEqual(p.Id, batch.Mapping_Profile__c, 'the faulty profile is recorded');
        Assert.isTrue(batch.Error_Message__c.contains('Column "Dealer Rep #" is not mapped'), 'error message: ' + batch.Error_Message__c);
    }

    @IsTest
    static void malformedFileFailsAndStagesNothing() {
        barderProfile(TestDataFactory.firm('Barder & Company').Id);
        Import_Batch__c batch = runAsIntegration(csv(new List<String>{ '09/13/2026,457,"Julia,Barder,Fund,100' }));
        Assert.areEqual(ImportBatchProcessor.STATUS_FAILED, batch.Status__c, 'unclosed quote');
        Assert.isTrue(batch.Error_Message__c.contains('Unclosed quoted value'), 'error message: ' + batch.Error_Message__c);
        Assert.isTrue(rowsFor(batch.Id).isEmpty(), 'all-or-nothing');
    }

    @IsTest
    static void headerOnlyFileFails() {
        Import_Batch__c batch = runAsIntegration(String.join(HEADERS, ',') + '\n');
        Assert.areEqual(ImportBatchProcessor.STATUS_FAILED, batch.Status__c, 'no data rows');
        Assert.isTrue(batch.Error_Message__c.contains('no data rows'), 'error message: ' + batch.Error_Message__c);
    }

    @IsTest
    static void batchWithoutFileFails() {
        User integration = TestDataFactory.integrationUser();
        Import_Batch__c batch;
        System.runAs(integration) {
            batch = new Import_Batch__c(Source_Firm__c = 'BARDER', File_Hash__c = 'abc', Status__c = ImportBatchProcessor.STATUS_RECEIVED);
            insert batch;
            Test.startTest();
            System.enqueueJob(new ImportBatchProcessor(batch.Id));
            Test.stopTest();
        }
        batch = [SELECT Status__c, Error_Message__c FROM Import_Batch__c WHERE Id = :batch.Id];
        Assert.areEqual(ImportBatchProcessor.STATUS_FAILED, batch.Status__c, 'no attachment');
        Assert.isTrue(batch.Error_Message__c.contains('No file is attached'), 'error message: ' + batch.Error_Message__c);
    }

    @IsTest
    static void onlyReceivedBatchesAreProcessed() {
        barderProfile(TestDataFactory.firm('Barder & Company').Id);
        Import_Batch__c batch = TestDataFactory.receivedBatch('BARDER', csv(new List<String>{ '09/13/2026,457,Julia,Barder,Fund,100' }));
        batch.Status__c = ImportBatchProcessor.STATUS_STAGED;
        update batch;
        Test.startTest();
        System.enqueueJob(new ImportBatchProcessor(batch.Id));
        Test.stopTest();
        Assert.isTrue(rowsFor(batch.Id).isEmpty(), 'a re-queued job must not stage the file twice');
        Assert.areEqual(ImportBatchProcessor.STATUS_STAGED, [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c, 'unchanged');
    }

    @IsTest
    static void rejectsFilesOverTheRowLimit() {
        barderProfile(TestDataFactory.firm('Barder & Company').Id);
        List<String> rows = new List<String>();
        for (Integer i = 0; i <= ImportBatchProcessor.MAX_ROWS; i++) {
            rows.add('09/13/2026,457,Julia,Barder,Fund,100');
        }
        Import_Batch__c batch = runAsIntegration(csv(rows));
        Assert.areEqual(ImportBatchProcessor.STATUS_FAILED, batch.Status__c, 'over the limit');
        Assert.isTrue(batch.Error_Message__c.contains('the limit is'), 'error message: ' + batch.Error_Message__c);
    }
}
