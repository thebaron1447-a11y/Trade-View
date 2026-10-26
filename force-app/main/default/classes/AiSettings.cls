/**
 * Claude settings, read from the Trade_AI_Setting__mdt record named Default. Custom metadata is deployable
 * configuration, so changing the model, the provider or switching Claude off needs no code change.
 * Provider: Models API (Enterprise tier, Einstein Trust Layer) unless the record says exactly Anthropic API
 * (Standard tier); any other value falls back to the Models API, the compliant default.
 * Tests set AiSettings.current directly, because custom metadata records cannot be inserted in a test.
 */
public with sharing class AiSettings {
    public static final String PROVIDER_MODELS_API = 'Models API';
    public static final String PROVIDER_ANTHROPIC = 'Anthropic API';
    public static final String DEFAULT_MODEL = 'sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet';
    public static final String DEFAULT_ANTHROPIC_MODEL = 'claude-sonnet-5-5';
    public static final Integer DEFAULT_MAX_ITEMS = 10;
    // Keeps each prompt small enough to answer well within the callout time limit.
    public static final Integer MAX_ITEMS_CAP = 25;

    public Boolean enabled = false;
    public String provider = PROVIDER_MODELS_API;
    /** Models API model name, used with the Models API provider. */
    public String modelName = DEFAULT_MODEL;
    /** Anthropic model ID, used with the Anthropic API provider. */
    public String anthropicModel = DEFAULT_ANTHROPIC_MODEL;
    public Integer maxItemsPerRequest = DEFAULT_MAX_ITEMS;
    public Boolean requireTwoPersonRuleApproval = true;

    @TestVisible
    private static AiSettings current;

    /** The model for the selected provider. */
    public String activeModel() {
        return provider == PROVIDER_ANTHROPIC ? anthropicModel : modelName;
    }

    public static AiSettings get() {
        if (current == null) {
            current = fromRecord(Trade_AI_Setting__mdt.getInstance('Default'));
        }
        return current;
    }

    /** With no record, Claude stays off and matching rules still need two people: the safe defaults. */
    @TestVisible
    private static AiSettings fromRecord(Trade_AI_Setting__mdt rec) {
        AiSettings s = new AiSettings();
        if (rec == null) {
            return s;
        }
        s.enabled = rec.Enabled__c == true;
        if (rec.Provider__c != null && rec.Provider__c.trim() == PROVIDER_ANTHROPIC) {
            s.provider = PROVIDER_ANTHROPIC;
        }
        if (String.isNotBlank(rec.Model_Name__c)) {
            s.modelName = rec.Model_Name__c.trim();
        }
        if (String.isNotBlank(rec.Anthropic_Model__c)) {
            s.anthropicModel = rec.Anthropic_Model__c.trim();
        }
        if (rec.Max_Items_Per_Request__c != null && rec.Max_Items_Per_Request__c >= 1) {
            s.maxItemsPerRequest = Math.min(rec.Max_Items_Per_Request__c.intValue(), MAX_ITEMS_CAP);
        }
        s.requireTwoPersonRuleApproval = rec.Require_Two_Person_Rule_Approval__c != false;
        return s;
    }
}
