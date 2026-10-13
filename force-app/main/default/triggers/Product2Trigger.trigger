trigger Product2Trigger on Product2(before delete) {
    ProductDeleteGuard.preventDeleteWithTrades(Trigger.oldMap);
}
