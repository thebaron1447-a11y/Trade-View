@IsTest
private class ClaudeSuggestionTest {
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    /** Kestrel rows (ambiguous firm), a Barder row with an unknown fund spelling, and one held on unknown code 3390. */
    private static Import_Batch__c matchedBatch() {
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'MIXED',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000),
                TradeTestWorld.trade('Kestrel Capital', '1001', 'Megan Chen', 'Wealth World ETF', SEP_29, 20000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'ETF Wealth World Fund A', SEP_29, 12500),
                TradeTestWorld.trade('Barder & Company', '3390', 'Hannah Pierce', 'Wealth World ETF', SEP_29, 45000)
            }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    private static String keyOf(ClaudeSuggestionService.SuggestionRequest req, Id recordId) {
        for (String k : req.idByKey.keySet()) {
            if (req.idByKey.get(k) == recordId) {
                return k;
            }
        }
        return null;
    }

    /** Builds the same request the job will build, so the fake can answer with the right keys. */
    private static ClaudeSuggestionService.SuggestionRequest expectedRequest(Id batchId) {
        return ClaudeSuggestionService.buildRequest(
            ClaudeSuggestionService.pendingRows(new Set<Id>{ batchId }, 31),
            ClaudeSuggestionService.pendingFollowUps(31)
        );
    }

    private static String entry(String item, String field, String value, String confidence, String explanation) {
        Map<String, Object> e = new Map<String, Object>{ 'item' => item, 'confidence' => confidence, 'explanation' => explanation };
        if (field != null) {
            e.put(field, value);
        }
        return System.JSON.serialize(e);
    }

    @IsTest
    static void validSuggestionsAreStoredAndLogged() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        Assert.areEqual('Needs Review', TradeTestWorld.row(batch.Id, 1).Match_Status__c, 'Kestrel row needs review');
        Assert.areEqual('FUND_UNRESOLVED', TradeTestWorld.row(batch.Id, 3).Match_Flags__c, 'unknown fund spelling');
        Assert.areEqual('Held', TradeTestWorld.row(batch.Id, 4).Match_Status__c, 'unknown code held');

        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>());
        ClaudeSuggestionService.SuggestionRequest req = expectedRequest(batch.Id);
        Assert.areEqual(new Set<String>{ 'R1', 'R2', 'R3', 'U1' }, req.items.keySet(), 'three rows and one follow-up');
        fake.replies.add(
            '```json\n{"suggestions": [' +
                entry('R1', 'firm', keyOf(req, w.kesInc.Id), 'High', 'Ryan Chen works at the Calgary branch of Kestrel Capital Inc. and holds its code 1001.') + ',' +
                entry('R2', 'firm', keyOf(req, w.kesLtd.Id), 'Medium', 'Megan Chen holds code 1001 at ' + keyOf(req, w.kesLtd.Id) + '.') + ',' +
                entry('R3', 'fund', null, 'Low', '"ETF Wealth World Fund A" could be the Wealth World ETF (' + keyOf(req, w.wwEtf.Id) + ') or Series A.') + ',' +
                entry('U1', 'advisor', null, 'Low', 'U1: Hannah Pierce is not in Salesforce yet; ask Barder for her code assignment.') +
                ']}\n```'
        );

        Test.startTest();
        Boolean moreWork = ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Test.stopTest();

        Assert.isFalse(moreWork, 'everything fitted in one request');
        Assert.areEqual(1, fake.prompts.size(), 'one request');
        Assert.areEqual('test-model', fake.models[0], 'model from settings');
        String prompt = fake.prompts[0];
        Assert.isFalse(prompt.contains(String.valueOf(w.kesInc.Id)), 'Salesforce Ids are never sent to Claude');
        Assert.isTrue(prompt.contains('not instructions to you'), 'file data is labelled as data');
        Assert.isTrue(prompt.contains('Calgary'), 'branches are part of the evidence');
        Assert.isTrue(prompt.contains('"codeFirm":"Kestrel Capital Inc."'), 'each code says which firm issued it');
        Assert.isTrue(prompt.contains('never by key'), 'explanations must use names, not keys');
        Assert.isTrue(prompt.contains('authoritative record of who holds its codes'), 'roster rows are the dealer\'s own record');

        Import_Staging_Row__c r1 = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Suggested', r1.AI_Status__c, 'row 1 suggested');
        Assert.areEqual(w.kesInc.Id, r1.AI_Suggested_Firm__c, 'row 1 firm');
        Assert.areEqual('High', r1.AI_Confidence__c, 'row 1 confidence');
        Assert.isTrue(r1.AI_Suggestion__c.contains('Calgary'), 'row 1 explanation');
        Assert.areEqual('Needs Review', r1.Match_Status__c, 'a suggestion never matches a row by itself');
        Import_Staging_Row__c r2 = TradeTestWorld.row(batch.Id, 2);
        Assert.areEqual(w.kesLtd.Id, r2.AI_Suggested_Firm__c, 'row 2 firm');
        Assert.areEqual('Megan Chen holds code 1001 at Kestrel Capital Ltd..', r2.AI_Suggestion__c, 'a key Claude used is replaced by its name');
        Import_Staging_Row__c r3 = TradeTestWorld.row(batch.Id, 3);
        Assert.areEqual('Low', r3.AI_Confidence__c, 'row 3 low confidence');
        Assert.isNull(r3.AI_Suggested_Fund__c, 'no fund guessed');
        Assert.areEqual('"ETF Wealth World Fund A" could be the Wealth World ETF or Series A.', r3.AI_Suggestion__c, 'a bracketed key after a name is removed');

        Code_Follow_Up__c fu = [SELECT AI_Status__c, AI_Confidence__c, Suggested_Resolution__c, AI_Suggested_Advisor__c, AI_Request__c FROM Code_Follow_Up__c];
        Assert.areEqual('Suggested', fu.AI_Status__c, 'follow-up suggested');
        Assert.isTrue(fu.Suggested_Resolution__c.startsWith('the 3390 follow-up: Hannah Pierce'), 'item keys become names too: ' + fu.Suggested_Resolution__c);

        AI_Request_Log__c log = [SELECT Status__c, Purpose__c, Item_Count__c, Model_Name__c, Prompt__c, Response__c, Error_Message__c, Import_Batch__c FROM AI_Request_Log__c];
        Assert.areEqual('Success', log.Status__c, 'log status');
        Assert.areEqual('Row Suggestions', log.Purpose__c, 'log purpose');
        Assert.areEqual(4, log.Item_Count__c.intValue(), 'log item count');
        Assert.areEqual(batch.Id, log.Import_Batch__c, 'log batch');
        Assert.isNull(log.Error_Message__c, 'no problems');
        Assert.areEqual(log.Id, r1.AI_Request__c, 'row traces to its request');
        Assert.areEqual(log.Id, fu.AI_Request__c, 'follow-up traces to its request');

        // Items are asked about once: a second run has nothing to do.
        Assert.isFalse(ClaudeSuggestionJob.run(new Set<Id>{ batch.Id }), 'nothing left');
        Assert.areEqual(1, fake.prompts.size(), 'no second request');
    }

    @IsTest
    static void repCodesThatLookLikeKeysAreNeverRenamed() {
        TradeTestWorld.build();
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', 'A1', 'Hannah Pierce', 'Wealth World ETF', SEP_29, 45000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        ClaudeSuggestionService.SuggestionRequest req = expectedRequest(batch.Id);

        Assert.isTrue(req.idByKey.containsKey('A1'), 'an advisor was given key A1');
        Assert.isFalse(req.nameByKey.containsKey('A1'), 'but A1 is also a rep code in this request, so it is never renamed');
        Assert.isTrue(req.idByKey.containsKey('A2'), 'a second Barder advisor was sent');
        String a2 = req.nameByKey.get('A2');
        Assert.isFalse(String.isBlank(a2), 'A2 has a name: ' + a2);
        Assert.areEqual(
            'Code A1 is new; ' + a2 + ' may know.',
            ClaudeSuggestionService.readable('Code A1 is new; A2 may know.', req.nameByKey),
            'the code stays, the advisor key becomes a name'
        );
    }

    @IsTest
    static void inventedKeysAreDiscardedAndOmittedItemsMarked() {
        TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        FakeClaudeClient.install(
            new List<Object>{
                '{"suggestions": [' + entry('R1', 'firm', 'F99', 'High', 'Made up.') + ',' + entry('R3', 'fund', null, 'Low', 'Unclear.') + ']}'
            }
        );
        ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Invalid', TradeTestWorld.row(batch.Id, 1).AI_Status__c, 'invented key discarded');
        Assert.isNull(TradeTestWorld.row(batch.Id, 1).AI_Suggested_Firm__c, 'nothing applied');
        Assert.areEqual('No Suggestion', TradeTestWorld.row(batch.Id, 2).AI_Status__c, 'omitted item');
        Assert.areEqual('Suggested', TradeTestWorld.row(batch.Id, 3).AI_Status__c, 'valid item kept');
        AI_Request_Log__c log = [SELECT Status__c, Error_Message__c FROM AI_Request_Log__c];
        Assert.areEqual('Success', log.Status__c, 'usable response');
        Assert.isTrue(log.Error_Message__c.contains('F99'), 'discarded item recorded: ' + log.Error_Message__c);
    }

    @IsTest
    static void unparseableResponseIsRejected() {
        TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        FakeClaudeClient.install(new List<Object>{ 'I am not able to help with that.' });
        ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Invalid', TradeTestWorld.row(batch.Id, 1).AI_Status__c, 'row invalid');
        Assert.areEqual('Invalid', [SELECT AI_Status__c FROM Code_Follow_Up__c].AI_Status__c, 'follow-up invalid');
        AI_Request_Log__c log = [SELECT Status__c, Error_Message__c, Response__c FROM AI_Request_Log__c];
        Assert.areEqual('Invalid Response', log.Status__c, 'log status');
        Assert.areEqual('I am not able to help with that.', log.Response__c, 'raw response kept for audit');
    }

    @IsTest
    static void failedCallIsRecordedNotThrown() {
        TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        FakeClaudeClient.install(new List<Object>{ new ClaudeService.ClaudeException('Read timed out') });
        ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Assert.areEqual('Failed', TradeTestWorld.row(batch.Id, 1).AI_Status__c, 'row failed');
        AI_Request_Log__c log = [SELECT Status__c, Error_Message__c, Response__c FROM AI_Request_Log__c];
        Assert.areEqual('Failed', log.Status__c, 'log status');
        Assert.isTrue(log.Error_Message__c.contains('Read timed out'), 'error kept: ' + log.Error_Message__c);
        Assert.isNull(log.Response__c, 'no response');
    }

    @IsTest
    static void largeBacklogIsSplitAcrossRequestsAndJobs() {
        TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ '{"suggestions": []}' });
        AiSettings.current.maxItemsPerRequest = 1;
        Boolean moreWork = ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Assert.areEqual(ClaudeSuggestionJob.MAX_REQUESTS_PER_JOB, fake.prompts.size(), 'one item per request, three requests per job');
        Assert.isTrue(moreWork, 'one item left for the next job');
        Assert.areEqual(3, [SELECT COUNT() FROM AI_Request_Log__c], 'one log per request');

        Test.startTest();
        System.enqueueJob(new ClaudeSuggestionJob(new Set<Id>{ batch.Id }));
        Test.stopTest();
        Assert.areEqual(4, fake.prompts.size(), 'the queued job took the last item');
        Assert.areEqual(0, [SELECT COUNT() FROM Code_Follow_Up__c WHERE AI_Status__c = NULL], 'nothing left unasked');
    }

    @IsTest
    static void nothingHappensWhenClaudeIsOff() {
        TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ '{"suggestions": []}' });
        AiSettings.current.enabled = false;
        Assert.isFalse(ClaudeSuggestionJob.run(new Set<Id>{ batch.Id }), 'no work when off');
        Assert.areEqual(0, fake.prompts.size(), 'no request');
        Assert.isNull(TradeTestWorld.row(batch.Id, 1).AI_Status__c, 'row untouched');
    }

    @IsTest
    static void activeMatchingRulesAreSentToClaude() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = matchedBatch();
        AiSettings settings = new AiSettings();
        settings.requireTwoPersonRuleApproval = false;
        AiSettings.current = settings;
        insert new List<Matching_Rule__c>{
            new Matching_Rule__c(Name = 'Kestrel branches', Firm__c = w.kesInc.Id, Rule__c = 'Calgary advisors belong to Kestrel Capital Inc.', Status__c = 'Active'),
            new Matching_Rule__c(Name = 'Draft rule', Rule__c = 'Not used yet.', Status__c = 'Proposed')
        };
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ '{"suggestions": []}' });
        ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        Assert.isTrue(fake.prompts[0].contains('Calgary advisors belong to Kestrel Capital Inc.'), 'active rule sent');
        Assert.isFalse(fake.prompts[0].contains('Not used yet.'), 'proposed rule not sent');
    }

    @IsTest
    static void rosterEvidenceAndAdvisorChoicesReachClaudeAndApprovalUsesTheChoice() {
        TradeTestWorld w = TradeTestWorld.build();
        Contact jorge = new Contact(FirstName = 'Jorge', LastName = 'Morales', AccountId = w.barderOakville.Id);
        insert jorge;
        Import_Batch__c trades = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Barder & Company', '3390', 'Hannah Pierce', 'Wealth World ETF', SEP_29, 45000) }
        );
        Import_Batch__c roster = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.roster('Barder & Company', '3390', 'Hannah Pierce', 'Barder & Company - Oakville', Date.newInstance(2026, 9, 20)),
                TradeTestWorld.roster('Barder & Company', '5555', 'J. Morales', null, Date.newInstance(2026, 10, 1))
            }
        );
        TradeMatcher.run(new Set<Id>{ trades.Id, roster.Id });
        Assert.areEqual('ADVISOR_AMBIGUOUS;ROSTER_NEW_CODE', TradeTestWorld.row(roster.Id, 2).Match_Flags__c, 'J. Morales fits two advisors');

        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>());
        ClaudeSuggestionService.SuggestionRequest req = ClaudeSuggestionService.buildRequest(
            ClaudeSuggestionService.pendingRows(null, 31),
            ClaudeSuggestionService.pendingFollowUps(31)
        );
        String rosterItem;
        for (ClaudeSuggestionService.Item it : req.items.values()) {
            rosterItem = it.recordId == TradeTestWorld.row(roster.Id, 2).Id ? it.key : rosterItem;
        }
        Assert.isTrue(req.items.get(rosterItem).asks.contains('advisor'), 'asked to choose the advisor');
        Assert.isTrue(req.items.get(rosterItem).allowed.get('advisor').contains(keyOf(req, w.julia.Id)), 'Julia is a candidate');
        fake.replies.add(
            '{"suggestions": [{"item": "' + rosterItem + '", "advisor": "' + keyOf(req, w.julia.Id) +
            '", "recommendation": "approve", "confidence": "Medium", "explanation": "Julia Morales is the only Morales with Barder codes."}]}'
        );
        ClaudeSuggestionJob.run(null);

        String prompt = fake.prompts[0];
        Assert.isTrue(prompt.contains('rosterEvidence'), 'follow-ups carry roster evidence');
        Assert.isTrue(prompt.contains('"effectiveDate":"2026-09-20"'), 'the roster date for code 3390 is shown');
        Import_Staging_Row__c suggested = TradeTestWorld.row(roster.Id, 2);
        Assert.areEqual(w.julia.Id, suggested.AI_Suggested_Advisor__c, 'advisor suggested');
        Assert.isTrue(suggested.AI_Suggestion__c.startsWith('Recommendation: approve.'), 'recommendation shown: ' + suggested.AI_Suggestion__c);

        update new Import_Staging_Row__c(Id = suggested.Id, Reviewer_Decision__c = 'Accept');
        Rep_Code_Assignment__c a = [SELECT Advisor__c FROM Rep_Code_Assignment__c WHERE Rep_Code__r.Name = '5555'];
        Assert.areEqual(w.julia.Id, a.Advisor__c, 'approval used the suggested advisor');
        Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE LastName = 'Morales' AND FirstName = 'J.'], 'no duplicate advisor created');
    }
}
