/**
 * A small reference world for phase 3B tests, shaped like the phase 1 seed: two Kestrel firms that share a
 * name and code 1001 (each held by a different advisor), and Barder with a solo code per advisor.
 */
@IsTest
public class TradeTestWorld {
    public Account kesInc;
    public Account kesLtd;
    public Account barder;
    public Account barderOakville;
    public Account barderHamilton;
    public Contact ryan;
    public Contact megan;
    public Contact julia;
    public Contact marcus;
    public Product2 wwfA;
    public Product2 wwEtf;
    public Rep_Code__c inc1001;
    public Rep_Code__c ltd1001;
    public Rep_Code__c b457;
    public Rep_Code__c b2210;

    public static TradeTestWorld build() {
        TradeTestWorld w = new TradeTestWorld();
        w.kesInc = new Account(Name = 'Kestrel Capital Inc.');
        w.kesLtd = new Account(Name = 'Kestrel Capital Ltd.');
        w.barder = new Account(Name = 'Barder & Company');
        insert new List<Account>{ w.kesInc, w.kesLtd, w.barder };
        Account calgary = new Account(Name = 'Kestrel Capital Inc. - Calgary', ParentId = w.kesInc.Id);
        Account vancouver = new Account(Name = 'Kestrel Capital Ltd. - Vancouver', ParentId = w.kesLtd.Id);
        w.barderOakville = new Account(Name = 'Barder & Company - Oakville', ParentId = w.barder.Id);
        w.barderHamilton = new Account(Name = 'Barder & Company - Hamilton', ParentId = w.barder.Id);
        insert new List<Account>{ calgary, vancouver, w.barderOakville, w.barderHamilton };

        w.ryan = new Contact(FirstName = 'Ryan', LastName = 'Chen', AccountId = calgary.Id);
        w.megan = new Contact(FirstName = 'Megan', LastName = 'Chen', AccountId = vancouver.Id);
        w.julia = new Contact(FirstName = 'Julia', LastName = 'Morales', AccountId = w.barderOakville.Id);
        w.marcus = new Contact(FirstName = 'Marcus', LastName = 'Bell', AccountId = w.barderHamilton.Id);
        insert new List<Contact>{ w.ryan, w.megan, w.julia, w.marcus };

        w.wwfA = new Product2(Name = 'Wealth World Fund - Series A', IsActive = true);
        w.wwEtf = new Product2(Name = 'Wealth World ETF', IsActive = true);
        insert new List<Product2>{ w.wwfA, w.wwEtf };

        insert new List<SObject>{
            new Firm_Alias__c(Name = 'Kestrel Capital Inc.', Normalized_Key__c = 'kestrel capital', Firm__c = w.kesInc.Id),
            new Firm_Alias__c(Name = 'Kestrel Capital Ltd.', Normalized_Key__c = 'kestrel capital', Firm__c = w.kesLtd.Id),
            new Firm_Alias__c(Name = 'Barder & Company', Normalized_Key__c = 'barder', Firm__c = w.barder.Id),
            new Fund_Alias__c(Name = 'Wealth World Fund - Series A', Normalized_Key__c = 'wealth world fund series a', Fund__c = w.wwfA.Id),
            new Fund_Alias__c(Name = 'Wealth World ETF', Normalized_Key__c = 'wealth world etf', Fund__c = w.wwEtf.Id)
        };

        w.inc1001 = new Rep_Code__c(Name = '1001', Firm__c = w.kesInc.Id);
        w.ltd1001 = new Rep_Code__c(Name = '1001', Firm__c = w.kesLtd.Id);
        w.b457 = new Rep_Code__c(Name = '457', Firm__c = w.barder.Id);
        w.b2210 = new Rep_Code__c(Name = '2210', Firm__c = w.barder.Id);
        insert new List<Rep_Code__c>{ w.inc1001, w.ltd1001, w.b457, w.b2210 };
        insert new List<Rep_Code_Assignment__c>{
            assignment(w.inc1001.Id, w.ryan.Id, 2023, 2, 1),
            assignment(w.ltd1001.Id, w.megan.Id, 2021, 6, 1),
            assignment(w.b457.Id, w.julia.Id, 2020, 1, 1),
            assignment(w.b2210.Id, w.marcus.Id, 2018, 1, 8)
        };
        return w;
    }

    private static Rep_Code_Assignment__c assignment(Id codeId, Id advisorId, Integer y, Integer m, Integer d) {
        return new Rep_Code_Assignment__c(Rep_Code__c = codeId, Advisor__c = advisorId, Allocation_Percent__c = 100, Effective_Start_Date__c = Date.newInstance(y, m, d));
    }

    /** A Staged batch with these rows (numbered in order), ready for TradeMatcher.run. */
    public static Import_Batch__c stagedBatch(String sourceFirm, List<Import_Staging_Row__c> rows) {
        Import_Batch__c batch = new Import_Batch__c(Source_Firm__c = sourceFirm, File_Hash__c = sourceFirm + Crypto.getRandomInteger(), Status__c = 'Staged');
        insert batch;
        Integer n = 0;
        for (Import_Staging_Row__c r : rows) {
            r.Import_Batch__c = batch.Id;
            r.Row_Number__c = ++n;
            r.Match_Status__c = 'Pending';
        }
        insert rows;
        return batch;
    }

    public static Import_Staging_Row__c trade(String firm, String code, String advisor, String fund, Date d, Decimal amount) {
        return new Import_Staging_Row__c(
            Row_Type__c = 'Trade',
            Source_Firm_Name__c = firm,
            Source_Rep_Code__c = code,
            Source_Advisor_Name__c = advisor,
            Source_Fund_Name__c = fund,
            Trade_Date__c = d,
            Transaction_Type__c = 'Purchase',
            Amount__c = amount
        );
    }

    public static Import_Staging_Row__c roster(String firm, String code, String advisor, String branch, Date d) {
        return new Import_Staging_Row__c(
            Row_Type__c = 'Code Roster',
            Source_Firm_Name__c = firm,
            Source_Rep_Code__c = code,
            Source_Advisor_Name__c = advisor,
            Source_Branch_Name__c = branch,
            Trade_Date__c = d
        );
    }

    public static Map<Id, Import_Staging_Row__c> rowsOf(Id batchId) {
        return new Map<Id, Import_Staging_Row__c>(
            [
                SELECT Id, Name, Row_Number__c, Row_Type__c, Match_Status__c, Match_Method__c, Match_Flags__c, Matched_Firm__c, Matched_Fund__c,
                    Credited_Advisor__c, Code_Follow_Up__c, AI_Status__c, AI_Confidence__c, AI_Suggestion__c, AI_Suggested_Firm__c,
                    AI_Suggested_Fund__c, AI_Suggested_Advisor__c, AI_Request__c, Firm_Override__c, Fund_Override__c,
                    Reviewer_Decision__c, Decided_By__c, Decided_At__c
                FROM Import_Staging_Row__c
                WHERE Import_Batch__c = :batchId
                ORDER BY Row_Number__c
            ]
        );
    }

    /** The row with this number in the batch. */
    public static Import_Staging_Row__c row(Id batchId, Integer rowNumber) {
        for (Import_Staging_Row__c r : rowsOf(batchId).values()) {
            if (r.Row_Number__c == rowNumber) {
                return r;
            }
        }
        return null;
    }
}
