@IsTest
private class ProductDeleteGuardTest {
    @IsTest
    static void blocksDeletingFundWithTradesOnly() {
        Account firm = TestDataFactory.firm('Barder & Company');
        Rep_Code__c code = TestDataFactory.repCode('457', firm.Id);
        Product2 traded = TestDataFactory.fund('Wealth World Fund - Series A');
        Product2 unused = TestDataFactory.fund('Global Bond Fund - Series F');
        TestDataFactory.trade(code.Id, traded.Id, 1000);

        Test.startTest();
        List<Database.DeleteResult> results = Database.delete(new List<Product2>{ traded, unused }, false);
        Test.stopTest();

        Assert.isFalse(results[0].isSuccess(), 'fund with trades must not be deleted');
        Assert.areEqual(ProductDeleteGuard.MESSAGE, results[0].getErrors()[0].getMessage(), 'clear message');
        Assert.isTrue(results[1].isSuccess(), 'unused fund can be deleted');
        Assert.areEqual(1, [SELECT COUNT() FROM Product2 WHERE Id = :traded.Id], 'traded fund kept');
    }

    @IsTest
    static void handlesEmptyInput() {
        ProductDeleteGuard.preventDeleteWithTrades(null);
        ProductDeleteGuard.preventDeleteWithTrades(new Map<Id, Product2>());
        Assert.isTrue(true, 'no exception for empty input');
    }
}
