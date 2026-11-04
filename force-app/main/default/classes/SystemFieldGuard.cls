/**
 * Refuses hand changes to fields the system owns on staging rows and code reviews (audit F-01, defence in depth).
 *
 * The Reviewer and Integration permission sets already make these fields read-only; this guard also stops changes
 * made in system mode by other code or automation. A change is allowed when the system writer is saving
 * (SystemWriter.isActive), or when the user holds the Trade Import Data Fix permission or Modify All Data. Field
 * history keeps the tracked fields' changes either way.
 *
 * PEOPLE_FIELDS must match the fields the Reviewer permission set may edit (gen_metadata.py REVIEWER_FIELDS);
 * SecurityModelTest checks the two agree.
 */
public with sharing class SystemFieldGuard {
    public static final String DATA_FIX_PERMISSION = 'Trade_Import_Data_Fix';

    /** What a person decides, by object; every other custom field is set by the system. Lower case. */
    public static final Map<SObjectType, Set<String>> PEOPLE_FIELDS = new Map<SObjectType, Set<String>>{
        Import_Staging_Row__c.SObjectType => new Set<String>{
            'advisor_override__c',
            'firm_override__c',
            'fund_override__c',
            'reviewer_decision__c',
            'remember_choice__c',
            'on_hold__c',
            'on_hold_reason__c',
            'assigned_to__c',
            'asked_firm_at__c'
        },
        Code_Follow_Up__c.SObjectType => new Set<String>{
            'status__c',
            'resolution_notes__c',
            'assigned_to__c',
            'asked_firm_at__c',
            'on_hold__c',
            'on_hold_reason__c'
        }
    };

    private static Map<SObjectType, Map<String, String>> guardedByType = new Map<SObjectType, Map<String, String>>();
    private static Map<Id, Boolean> mayFixByUser = new Map<Id, Boolean>();

    /** Before update: adds an error to each record whose system-owned fields changed outside the system writer. */
    public static void check(List<SObject> records, Map<Id, SObject> previous) {
        if (records == null || records.isEmpty() || SystemWriter.isActive() || mayFixData()) {
            return;
        }
        Map<String, String> guarded = guardedFields(records[0].getSObjectType());
        for (SObject r : records) {
            SObject before = previous.get(r.Id);
            for (String field : guarded.keySet()) {
                if (!same(r.get(field), before.get(field))) {
                    r.addError(field, guarded.get(field) + ' is set by the system and cannot be changed by hand.');
                    break;
                }
            }
        }
    }

    /** The system-owned fields of a type (custom, not formula or roll-up, not decided by a person), by API name to label. */
    @TestVisible
    private static Map<String, String> guardedFields(SObjectType t) {
        if (!guardedByType.containsKey(t)) {
            Set<String> people = PEOPLE_FIELDS.containsKey(t) ? PEOPLE_FIELDS.get(t) : new Set<String>();
            Map<String, String> result = new Map<String, String>();
            for (SObjectField f : t.getDescribe().fields.getMap().values()) {
                DescribeFieldResult d = f.getDescribe();
                String name = d.getName().toLowerCase();
                if (d.isCustom() && !d.isCalculated() && !d.isAutoNumber() && !people.contains(name)) {
                    result.put(d.getName(), d.getLabel());
                }
            }
            guardedByType.put(t, result);
        }
        return guardedByType.get(t);
    }

    /**
     * Data fixes: the Trade Import Data Fix permission (Trade Import Admin) or Modify All Data. Checked once per user.
     * The custom permission is also read from the user's permission set assignments, because FeatureManagement does not
     * always see a permission deployed in the same deployment while its tests run.
     */
    public static Boolean mayFixData() {
        Id me = UserInfo.getUserId();
        if (!mayFixByUser.containsKey(me)) {
            Boolean allowed =
                FeatureManagement.checkPermission(DATA_FIX_PERMISSION) ||
                [
                    SELECT COUNT()
                    FROM SetupEntityAccess
                    WHERE
                        SetupEntityId IN (SELECT Id FROM CustomPermission WHERE DeveloperName = :DATA_FIX_PERMISSION)
                        AND ParentId IN (SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :me)
                ] > 0 ||
                [SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :me AND PermissionSet.PermissionsModifyAllData = TRUE] > 0;
            mayFixByUser.put(me, allowed);
        }
        return mayFixByUser.get(me);
    }

    /** Equal values, with text compared exactly (Apex's == ignores case). */
    private static Boolean same(Object a, Object b) {
        if (a == null || b == null) {
            return a == b;
        }
        if (a instanceof String && b instanceof String) {
            return ((String) a).equals((String) b);
        }
        return a == b;
    }
}
