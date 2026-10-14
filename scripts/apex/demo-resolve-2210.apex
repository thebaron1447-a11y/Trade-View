// Demo: Barder confirms that rep code 2210 moved from Marcus Bell to Priya Nair on 2026-09-15.
// Records that fact, then resolves the "Reassignment Suspected" follow-up, which releases the held
// rows and re-matches them in the background (they should come back Matched, credited to Priya Nair).
// Run after the trade files have been pushed and matched. Safe to re-run.
// Run: sf apex run --file scripts/apex/demo-resolve-2210.apex --target-org tradeDemo
Date handoverDate = Date.newInstance(2026, 9, 15);

Account branch = [SELECT Id FROM Account WHERE Name = 'Barder & Company - Hamilton' LIMIT 1];
Rep_Code__c code = [SELECT Id FROM Rep_Code__c WHERE Name = '2210' AND Firm__r.Name = 'Barder & Company' LIMIT 1];

List<Contact> priyas = [SELECT Id FROM Contact WHERE FirstName = 'Priya' AND LastName = 'Nair' AND AccountId = :branch.Id LIMIT 1];
Contact priya = priyas.isEmpty() ? new Contact(FirstName = 'Priya', LastName = 'Nair', AccountId = branch.Id) : priyas[0];
if (priya.Id == null) {
    insert priya;
}

// End Marcus Bell's share first: the rep code allows at most 100% across assignments with no end date.
List<Rep_Code_Assignment__c> endingShares = [
    SELECT Id FROM Rep_Code_Assignment__c
    WHERE Rep_Code__c = :code.Id AND Advisor__r.LastName = 'Bell' AND Effective_End_Date__c = null
];
for (Rep_Code_Assignment__c a : endingShares) {
    a.Effective_End_Date__c = handoverDate.addDays(-1);
    a.End_Date_Source__c = 'Confirmed by Firm';
}
update endingShares;

if ([SELECT COUNT() FROM Rep_Code_Assignment__c WHERE Rep_Code__c = :code.Id AND Advisor__c = :priya.Id] == 0) {
    insert new Rep_Code_Assignment__c(
        Rep_Code__c = code.Id,
        Advisor__c = priya.Id,
        Allocation_Percent__c = 100,
        Effective_Start_Date__c = handoverDate
    );
}

List<Code_Follow_Up__c> followUps = [
    SELECT Id, Status__c FROM Code_Follow_Up__c
    WHERE Follow_Up_Key__c = 'BARDER|2210|Reassignment Suspected'
    LIMIT 1
];
if (followUps.isEmpty()) {
    System.debug(LoggingLevel.WARN, 'No follow-up for BARDER 2210 yet. Push the trade files first.');
} else if (followUps[0].Status__c != 'Resolved') {
    followUps[0].Status__c = 'Resolved';
    followUps[0].Resolution_Notes__c = 'Firm confirmed Priya Nair took over code 2210 on 2026-09-15 (Marcus Bell ended 2026-09-14).';
    update followUps;
    System.debug(LoggingLevel.INFO, 'Follow-up resolved; held rows are being re-matched.');
}
