@IsTest
private class MappingProposalTest {
    private static final String KESTREL_CSV =
        'Representative,Rep No.,Organisation,Security Name,Settle Date,Side,Value\n' +
        'Ryan Chen,1001,Kestrel Capital,Wealth World Fund - Series A,2026-09-29,B,"50,000.00"\n' +
        'Megan Chen,1001,Kestrel Capital,Wealth World ETF,2026-09-30,S,"20,000.00"\n';

    private static final String GOOD_PROPOSAL = System.JSON.serialize(
        new Map<String, Object>{
            'feedType' => 'Trade Activity',
            'columnMap' => new Map<String, String>{
                'Representative' => 'advisorName',
                'Rep No.' => 'repCode',
                'Organisation' => 'firmName',
                'Security Name' => 'fundName',
                'Settle Date' => 'tradeDate',
                'Side' => 'transactionType',
                'Value' => 'amount'
            },
            'dateFormat' => 'YYYY-MM-DD',
            'decimalSeparator' => 'Period',
            'directionConvention' => 'Type Column',
            'aumIndicatorValues' => null,
            'confidence' => 'High',
            'explanation' => 'Side holds B for buy and S for sell. Settle Date is the only date column.'
        }
    );

    /** A Kestrel file that no profile can read: Mapping Review with its layout fingerprint saved. */
    private static Import_Batch__c waitingBatch() {
        Import_Batch__c batch = TestDataFactory.receivedBatch('KESTREL', KESTREL_CSV);
        new ImportBatchProcessor(batch.Id).execute(null);
        batch = [SELECT Id, Status__c, Header_Fingerprint__c FROM Import_Batch__c WHERE Id = :batch.Id];
        Assert.areEqual('Mapping Review', batch.Status__c, 'no profile for this layout');
        Assert.isNotNull(batch.Header_Fingerprint__c, 'layout remembered');
        return batch;
    }

    @IsTest
    static void claudesProposalBecomesADraftAndActivatingItFinishesTheFile() {
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = waitingBatch();
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ GOOD_PROPOSAL });

        Mapping_Profile__c draft = MappingProposalJob.run(batch.Id);

        Assert.isNotNull(draft, 'a draft was proposed');
        Assert.isTrue(fake.prompts[0].contains('Representative'), 'headers sent');
        Assert.isTrue(fake.prompts[0].contains('Megan Chen'), 'sample rows sent');
        draft = [SELECT Status__c, Source_Firm__c, Header_Fingerprint__c, AI_Rationale__c, Proposed_From_Batch__c, Date_Format__c, Feed_Type__c FROM Mapping_Profile__c WHERE Id = :draft.Id];
        Assert.areEqual('Draft', draft.Status__c, 'never activated by Claude');
        Assert.areEqual('KESTREL', draft.Source_Firm__c, 'source firm');
        Assert.areEqual(batch.Header_Fingerprint__c, draft.Header_Fingerprint__c, 'same layout');
        Assert.areEqual(batch.Id, draft.Proposed_From_Batch__c, 'traceable to the file');
        Assert.isTrue(draft.AI_Rationale__c.contains('Checks passed'), 'rationale: ' + draft.AI_Rationale__c);
        Assert.isTrue(draft.AI_Rationale__c.contains('Side holds B'), 'Claude explanation kept');
        Assert.isTrue([SELECT Error_Message__c FROM Import_Batch__c WHERE Id = :batch.Id].Error_Message__c.contains('Claude proposed a mapping'), 'batch says what to do next');
        Assert.areEqual('Success', [SELECT Status__c FROM AI_Request_Log__c].Status__c, 'logged');

        // One proposal per layout.
        Assert.isNull(MappingProposalJob.run(batch.Id), 'no second proposal');
        Assert.areEqual(1, fake.prompts.size(), 'no second request');

        Test.startTest();
        update new Mapping_Profile__c(Id = draft.Id, Status__c = 'Active');
        Test.stopTest(); // the activation re-queues the waiting batch

        Assert.areEqual('Staged', [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c, 'file read with the new profile');
        Assert.areEqual(2, [SELECT COUNT() FROM Import_Staging_Row__c WHERE Import_Batch__c = :batch.Id AND Has_Errors__c = FALSE], 'both rows staged cleanly');

        // The rest of the Kestrel story: the firm name fits two firms, Claude tells them apart by advisor, a reviewer accepts.
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Assert.areEqual('FIRM_AMBIGUOUS', TradeTestWorld.row(batch.Id, 1).Match_Flags__c, 'two Kestrel firms');
        ClaudeSuggestionService.SuggestionRequest req = ClaudeSuggestionService.buildRequest(
            ClaudeSuggestionService.pendingRows(new Set<Id>{ batch.Id }, 31),
            ClaudeSuggestionService.pendingFollowUps(31)
        );
        String inc;
        String ltd;
        for (String k : req.idByKey.keySet()) {
            inc = req.idByKey.get(k) == w.kesInc.Id ? k : inc;
            ltd = req.idByKey.get(k) == w.kesLtd.Id ? k : ltd;
        }
        fake.replies.clear();
        fake.replies.add(
            '{"suggestions": [{"item": "R1", "firm": "' + inc + '", "confidence": "High", "explanation": "Ryan Chen is at the Calgary branch of Kestrel Capital Inc."},' +
            ' {"item": "R2", "firm": "' + ltd + '", "confidence": "High", "explanation": "Megan Chen is at the Vancouver branch of Kestrel Capital Ltd."}]}'
        );
        ClaudeSuggestionJob.run(new Set<Id>{ batch.Id });
        update new List<Import_Staging_Row__c>{
            new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 1).Id, Reviewer_Decision__c = 'Accept'),
            new Import_Staging_Row__c(Id = TradeTestWorld.row(batch.Id, 2).Id, Reviewer_Decision__c = 'Accept')
        };
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Import_Staging_Row__c ryanRow = TradeTestWorld.row(batch.Id, 1);
        Import_Staging_Row__c meganRow = TradeTestWorld.row(batch.Id, 2);
        Assert.areEqual('Matched', ryanRow.Match_Status__c, 'Ryan row matched');
        Assert.areEqual(w.ryan.Id, ryanRow.Credited_Advisor__c, 'credited to Ryan Chen at Kestrel Inc.');
        Assert.areEqual('Matched', meganRow.Match_Status__c, 'Megan row matched');
        Assert.areEqual(w.megan.Id, meganRow.Credited_Advisor__c, 'credited to Megan Chen at Kestrel Ltd.');
        Assert.areEqual('Claude', meganRow.Match_Method__c, 'via the accepted suggestion');
    }

    @IsTest
    static void invalidProposalCreatesNothing() {
        TradeTestWorld.build();
        Import_Batch__c batch = waitingBatch();
        Map<String, Object> bad = (Map<String, Object>) System.JSON.deserializeUntyped(GOOD_PROPOSAL);
        ((Map<String, Object>) bad.get('columnMap')).put('Value', 'units');
        FakeClaudeClient.install(new List<Object>{ System.JSON.serialize(bad) });

        Assert.isNull(MappingProposalJob.run(batch.Id), 'nothing proposed');
        Assert.areEqual(0, [SELECT COUNT() FROM Mapping_Profile__c], 'no profile');
        AI_Request_Log__c log = [SELECT Status__c, Error_Message__c FROM AI_Request_Log__c];
        Assert.areEqual('Invalid Response', log.Status__c, 'rejected');
        Assert.isTrue(log.Error_Message__c.contains('units'), 'error: ' + log.Error_Message__c);
    }

    @IsTest
    static void proposalThatFailsTheFileChecksIsKeptWithTheProblemsShown() {
        TradeTestWorld.build();
        Import_Batch__c batch = waitingBatch();
        Map<String, Object> proposal = (Map<String, Object>) System.JSON.deserializeUntyped(GOOD_PROPOSAL);
        ((Map<String, Object>) proposal.get('columnMap')).put('Security Name', 'IGNORE');
        FakeClaudeClient.install(new List<Object>{ System.JSON.serialize(proposal) });

        Mapping_Profile__c draft = MappingProposalJob.run(batch.Id);
        String rationale = [SELECT AI_Rationale__c FROM Mapping_Profile__c WHERE Id = :draft.Id].AI_Rationale__c;
        Assert.isTrue(rationale.contains('problems to fix'), 'rationale: ' + rationale);
        Assert.isTrue(rationale.contains('fundName'), 'the missing required field is named: ' + rationale);
    }

    @IsTest
    static void nothingIsAskedWhenClaudeIsOffOrTheBatchIsNotWaiting() {
        TradeTestWorld.build();
        Import_Batch__c batch = waitingBatch();
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ GOOD_PROPOSAL });
        AiSettings.current.enabled = false;
        Assert.isNull(MappingProposalJob.run(batch.Id), 'off');
        AiSettings.current.enabled = true;
        update new Import_Batch__c(Id = batch.Id, Status__c = 'Failed');
        Assert.isNull(MappingProposalJob.run(batch.Id), 'not waiting for a mapping');
        Assert.areEqual(0, fake.prompts.size(), 'no request');
    }

    @IsTest
    static void queuedJobRuns() {
        TradeTestWorld.build();
        Import_Batch__c batch = waitingBatch();
        FakeClaudeClient.install(new List<Object>{ GOOD_PROPOSAL });
        Test.startTest();
        System.enqueueJob(new MappingProposalJob(batch.Id));
        Test.stopTest();
        Assert.areEqual(1, [SELECT COUNT() FROM Mapping_Profile__c WHERE Status__c = 'Draft'], 'draft created by the queued job');
    }
}
