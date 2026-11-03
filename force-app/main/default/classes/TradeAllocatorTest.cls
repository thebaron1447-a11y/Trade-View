@IsTest
private class TradeAllocatorTest {
    // The allocator never reads records, so advisors are stand-in Contact Ids.
    private static final Id ADVISOR_A = fakeContactId(1);
    private static final Id ADVISOR_B = fakeContactId(2);
    private static final Id ADVISOR_C = fakeContactId(3);

    private static Id fakeContactId(Integer n) {
        return Id.valueOf(Contact.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + String.valueOf(n).leftPad(12, '0'));
    }

    private static List<TradeAllocator.Share> shares(List<Decimal> percents) {
        List<Id> advisors = new List<Id>{ ADVISOR_A, ADVISOR_B, ADVISOR_C };
        List<TradeAllocator.Share> result = new List<TradeAllocator.Share>();
        for (Integer i = 0; i < percents.size(); i++) {
            result.add(new TradeAllocator.Share(advisors[i], percents[i]));
        }
        return result;
    }

    private static Decimal sum(List<TradeAllocator.Share> split) {
        Decimal total = 0;
        for (TradeAllocator.Share s : split) {
            total += s.amount;
        }
        return total;
    }

    @IsTest
    static void oneAdvisorGetsItAll() {
        List<TradeAllocator.Share> split = TradeAllocator.split(1234.56, shares(new List<Decimal>{ 100 }));
        Assert.areEqual(1234.56, split[0].amount, 'the whole amount');
    }

    @IsTest
    static void leftoverCentsGoToTheLargestShare() {
        // 60% of 1,000.01 is 600.006 and 40% is 400.004: rounded down they leave one cent, which goes to the 60%.
        List<TradeAllocator.Share> split = TradeAllocator.split(1000.01, shares(new List<Decimal>{ 40, 60 }));
        Assert.areEqual(400.00, split[0].amount, '40% rounded down');
        Assert.areEqual(600.01, split[1].amount, '60% gets the cent');
        Assert.areEqual(1000.01, sum(split), 'the parts add up to the whole');
    }

    @IsTest
    static void thirdsAddUpExactly() {
        List<TradeAllocator.Share> split = TradeAllocator.split(10, shares(new List<Decimal>{ 33.33, 33.33, 33.34 }));
        Assert.areEqual(3.33, split[0].amount, 'first third');
        Assert.areEqual(3.33, split[1].amount, 'second third');
        Assert.areEqual(3.34, split[2].amount, 'the largest share takes the cent');
        Assert.areEqual(10.00, sum(split), 'adds up');
    }

    @IsTest
    static void equalSharesKeepTheirOrder() {
        List<TradeAllocator.Share> split = TradeAllocator.split(0.05, shares(new List<Decimal>{ 50, 50 }));
        Assert.areEqual(0.03, split[0].amount, 'the first of equal shares takes the cent');
        Assert.areEqual(0.02, split[1].amount, 'the second does not');
    }

    @IsTest
    static void redemptionsSplitAsNegatives() {
        List<TradeAllocator.Share> split = TradeAllocator.split(-100.01, shares(new List<Decimal>{ 50, 50 }));
        Assert.areEqual(-50.01, split[0].amount, 'the first share takes the negative cent');
        Assert.areEqual(-50.00, split[1].amount, 'the second is rounded towards zero');
        Assert.areEqual(-100.01, sum(split), 'adds up to the signed amount');
    }

    @IsTest
    static void sharesMustTotalOneHundred() {
        for (List<Decimal> bad : new List<List<Decimal>>{ new List<Decimal>{ 60, 30 }, new List<Decimal>{ 100, 0 }, new List<Decimal>() }) {
            try {
                TradeAllocator.split(100, shares(bad));
                Assert.fail('refused: ' + bad);
            } catch (IllegalArgumentException e) {
                Assert.isTrue(String.isNotBlank(e.getMessage()), 'says why');
            }
        }
    }
}
