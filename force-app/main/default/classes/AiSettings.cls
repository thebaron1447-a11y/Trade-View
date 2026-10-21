/**
 * Claude settings, read from the Trade_AI_Setting__mdt record named Default. Custom metadata is deployable
 * configuration, so changing the model or switching Claude off needs no code change.
 * Tests set AiSettings.current directly, because custom metadata records cannot be inserted in a test.
 */
public with sharing class AiSettings {
    public static final String DEFAULT_MODEL = 'sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet';
    public static final Integer DEFAULT_MAX_ITEMS = 10;
    // Keeps each prompt small enough to answer well within the callout time limit.
    public static final Integer MAX_ITEMS_CAP = 25;

    public Boolean enabled = false;
    public String modelName = DEFAULT_MODEL;
    public Integer maxItemsPerRequest = DEFAULT_MAX_ITEMS;
    public Boolean requireTwoPersonRuleApproval = true;

    @TestVisible
    private static AiSettings current;

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
        if (String.isNotBlank(rec.Model_Name__c)) {
            s.modelName = rec.Model_Name__c.trim();
        }
        if (rec.Max_Items_Per_Request__c != null && rec.Max_Items_Per_Request__c >= 1) {
            s.maxItemsPerRequest = Math.min(rec.Max_Items_Per_Request__c.intValue(), MAX_ITEMS_CAP);
        }
        s.requireTwoPersonRuleApproval = rec.Require_Two_Person_Rule_Approval__c != false;
        return s;
    }
}
