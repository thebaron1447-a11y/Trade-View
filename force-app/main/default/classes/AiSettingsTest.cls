@IsTest
private class AiSettingsTest {
    // Custom metadata fields cannot be assigned in Apex, so test records are built from JSON.
    private static Trade_AI_Setting__mdt record(String json) {
        return (Trade_AI_Setting__mdt) System.JSON.deserialize(json, Trade_AI_Setting__mdt.class);
    }

    @IsTest
    static void missingRecordMeansOffAndTwoPerson() {
        AiSettings s = AiSettings.fromRecord(null);
        Assert.isFalse(s.enabled, 'off without a record');
        Assert.isTrue(s.requireTwoPersonRuleApproval, 'two-person by default');
        Assert.areEqual(AiSettings.DEFAULT_MODEL, s.modelName, 'default model');
        Assert.areEqual(AiSettings.DEFAULT_MAX_ITEMS, s.maxItemsPerRequest, 'default batch size');
    }

    @IsTest
    static void recordValuesAreReadAndBounded() {
        AiSettings s = AiSettings.fromRecord(
            record('{"Enabled__c": true, "Model_Name__c": "  my-model ", "Max_Items_Per_Request__c": 500, "Require_Two_Person_Rule_Approval__c": false}')
        );
        Assert.isTrue(s.enabled, 'on');
        Assert.areEqual('my-model', s.modelName, 'trimmed model name');
        Assert.areEqual(AiSettings.MAX_ITEMS_CAP, s.maxItemsPerRequest, 'capped');
        Assert.isFalse(s.requireTwoPersonRuleApproval, 'single person allowed');

        AiSettings zero = AiSettings.fromRecord(record('{"Max_Items_Per_Request__c": 0, "Model_Name__c": " "}'));
        Assert.areEqual(AiSettings.DEFAULT_MAX_ITEMS, zero.maxItemsPerRequest, 'zero ignored');
        Assert.areEqual(AiSettings.DEFAULT_MODEL, zero.modelName, 'blank model ignored');
    }

    @IsTest
    static void deployedRecordIsReadOnce() {
        AiSettings first = AiSettings.get();
        Assert.isNotNull(first, 'settings available');
        Assert.areEqual(first, AiSettings.get(), 'cached for the transaction');
    }
}
