/**
 * Blocks deleting a fund (Product2) that trades reference. Salesforce does not allow
 * delete-restricted lookups to Product2, so Trade__c.Fund__c would otherwise be blanked.
 *
 * Runs without sharing on purpose: the check must see every trade, including trades
 * not shared with the user attempting the delete.
 */
public without sharing class ProductDeleteGuard {
    public static final String MESSAGE = 'This fund has trades and cannot be deleted. Deactivate it instead.';

    public static void preventDeleteWithTrades(Map<Id, Product2> oldMap) {
        if (oldMap == null || oldMap.isEmpty()) {
            return;
        }
        Set<Id> productIds = oldMap.keySet();
        List<AggregateResult> usage = [
            SELECT Fund__c fundId
            FROM Trade__c
            WHERE Fund__c IN :productIds
            WITH SYSTEM_MODE
            GROUP BY Fund__c
        ];
        for (AggregateResult ar : usage) {
            oldMap.get((Id) ar.get('fundId')).addError(MESSAGE);
        }
    }
}
