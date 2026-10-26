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
        Assert.areEqual(AiSettings.PROVIDER_MODELS_API, s.provider, 'Models API unless chosen otherwise');
        Assert.areEqual(AiSettings.DEFAULT_MODEL, s.activeModel(), 'Models API model in use');
    }

    @IsTest
    static void providerChoosesTheRouteAndTheModel() {
        AiSettings anthropic = AiSettings.fromRecord(
            record('{"Provider__c": "Anthropic API", "Model_Name__c": "sfdc_ai__X", "Anthropic_Model__c": " claude-test "}')
        );
        Assert.areEqual(AiSettings.PROVIDER_ANTHROPIC, anthropic.provider, 'Standard tier chosen');
        Assert.areEqual('claude-test', anthropic.activeModel(), 'Anthropic model in use, trimmed');

        AiSettings models = AiSettings.fromRecord(record('{"Provider__c": "Models API", "Model_Name__c": "sfdc_ai__X"}'));
        Assert.areEqual(AiSettings.PROVIDER_MODELS_API, models.provider, 'Enterprise tier');
        Assert.areEqual('sfdc_ai__X', models.activeModel(), 'Models API model in use');

        AiSettings noAnthropicModel = AiSettings.fromRecord(record('{"Provider__c": "Anthropic API", "Anthropic_Model__c": " "}'));
        Assert.areEqual(AiSettings.DEFAULT_ANTHROPIC_MODEL, noAnthropicModel.activeModel(), 'blank Anthropic model falls back to the default');

        for (String other : new List<String>{ null, '', 'OpenAI', 'Anthropic' }) {
            AiSettings s = AiSettings.fromRecord(record(System.JSON.serialize(new Map<String, Object>{ 'Provider__c' => other })));
            Assert.areEqual(AiSettings.PROVIDER_MODELS_API, s.provider, 'anything but exactly Anthropic API stays on the Models API: ' + other);
        }
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
