@IsTest
public class TestDataFactory {
    public static final String SIGNED = MappingService.CONVENTION_SIGNED;
    public static final String TYPE_COLUMN = MappingService.CONVENTION_TYPE_COLUMN;

    /** A Standard User with only the integration permission set: proves the push job's least-privilege access works. */
    public static User integrationUser() {
        return userWithPermissionSets(new List<String>{ 'Trade_Import_Integration' });
    }

    public static User userWithPermissionSets(List<String> permissionSetNames) {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Math.abs(Crypto.getRandomInteger())) + String.valueOf(System.now().getTime());
        User u = new User(
            Alias = 'tiuser',
            Email = 'trade.import.tester@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Import Tester',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York',
            ProfileId = standard.Id,
            Username = 'trade.import.' + unique + '@example.com.test'
        );
        // Setup objects (User, PermissionSetAssignment) are inserted in their own context to avoid mixed DML.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
            }
            Assert.areEqual(permissionSetNames.size(), assignments.size(), 'All permission sets must exist in the org');
            insert assignments;
        }
        return u;
    }

    public static Account firm(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    public static Mapping_Profile__c profile(
        String firmCode,
        List<String> headers,
        Map<String, String> columnMap,
        String dateFormat,
        String decimalSeparator,
        String convention
    ) {
        return new Mapping_Profile__c(
            Name = firmCode + ' test profile',
            Source_Firm__c = firmCode,
            Header_Fingerprint__c = MappingService.fingerprint(headers),
            Column_Map__c = System.JSON.serialize(columnMap),
            Date_Format__c = dateFormat,
            Decimal_Separator__c = decimalSeparator,
            Direction_Convention__c = convention,
            Status__c = 'Active'
        );
    }

    /** Inserts a Received batch with the CSV attached, the same way the REST endpoint does. */
    public static Import_Batch__c receivedBatch(String firmCode, String csv) {
        Blob file = Blob.valueOf(csv);
        Import_Batch__c batch = new Import_Batch__c(
            Source_Firm__c = firmCode,
            Source_File_Name__c = firmCode + '.csv',
            File_Hash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', file)),
            Status__c = ImportBatchProcessor.STATUS_RECEIVED
        );
        insert batch;
        insert new ContentVersion(Title = batch.Source_File_Name__c, PathOnClient = batch.Source_File_Name__c, VersionData = file, FirstPublishLocationId = batch.Id);
        return batch;
    }

    public static Product2 fund(String name) {
        Product2 p = new Product2(Name = name, IsActive = true);
        insert p;
        return p;
    }

    public static Rep_Code__c repCode(String code, Id firmId) {
        Rep_Code__c rc = new Rep_Code__c(Name = code, Firm__c = firmId);
        insert rc;
        return rc;
    }

    public static Trade__c trade(Id repCodeId, Id fundId, Decimal amount) {
        Trade__c t = new Trade__c(
            Rep_Code__c = repCodeId,
            Fund__c = fundId,
            Trade_Date__c = Date.newInstance(2026, 9, 13),
            Transaction_Type__c = 'Purchase',
            Amount__c = amount
        );
        insert t;
        return t;
    }
}
