@IsTest
private class ReviewControllerTest {
    private static final Date SEP_27 = Date.newInstance(2026, 9, 27);
    private static final Date SEP_29 = Date.newInstance(2026, 9, 29);

    /** Claude off unless a test turns it on, so nothing is queued for it. */
    private static void claudeOff() {
        AiSettings.current = new AiSettings();
    }

    /**
     * Row 1: Kestrel, firm ambiguous, with Claude's suggestion. Row 2: Barder, fund spelling unknown, no suggestion.
     * Row 3: Barder on unknown code 3390 (held, raises a follow-up).
     */
    private static Import_Batch__c reviewBatch(TradeTestWorld w) {
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'MIXED',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Kestrel Capital', '1001', 'Ryan Chen', 'Wealth World Fund - Series A', SEP_29, 50000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'ETF Wealth World Fund A', SEP_29, 12500),
                TradeTestWorld.trade('Barder & Company', '3390', 'Hannah Pierce', 'Wealth World ETF', SEP_27, 45000)
            }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        update new Import_Staging_Row__c(
            Id = TradeTestWorld.row(batch.Id, 1).Id,
            AI_Status__c = 'Suggested',
            AI_Confidence__c = 'High',
            AI_Suggested_Firm__c = w.kesInc.Id,
            AI_Suggestion__c = 'Ryan Chen works at the Calgary branch of Kestrel Capital Inc.'
        );
        return batch;
    }

    private static ReviewController.RowItem rowOf(ReviewController.Queue q, Id rowId) {
        for (ReviewController.RowItem r : q.rows) {
            if (r.id == rowId) {
                return r;
            }
        }
        return null;
    }

    private static String failureOf(Id rowId, String decision, Id firmId, Id fundId) {
        try {
            ReviewController.decideRow(rowId, decision, firmId, fundId, null, false);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }

    private static User otherUser() {
        return TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });
    }

    @IsTest
    static void queueShowsRowsReasonsClaudeAndFollowUps() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id kestrelId = TradeTestWorld.row(batch.Id, 1).Id;
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;

        ReviewController.Queue q = ReviewController.getQueue('all');

        Assert.areEqual(2, q.rows.size(), 'two rows need review; the held row is a follow-up');
        ReviewController.RowItem kestrel = rowOf(q, kestrelId);
        Assert.isTrue(kestrel.needsFirm, 'firm needed');
        Assert.isFalse(kestrel.needsFund, 'fund known');
        Assert.isTrue(kestrel.claudeAnswersIt, 'Claude answered the firm');
        Assert.areEqual('Kestrel Capital Inc.', kestrel.aiFirmName, 'suggested firm by name');
        Assert.areEqual('Firm unclear', kestrel.issueType, 'issue type column');
        Assert.areEqual(1, kestrel.issueCount, 'one issue');
        Assert.isFalse(kestrel.isCodeIssue, 'a firm question stays in Needs Decision');
        Assert.areEqual(new List<String>{ 'The firm name fits more than one firm' }, kestrel.reasons, 'reason in plain words');
        Assert.areEqual('MIXED', kestrel.sourceFirm, 'file it came from');
        Assert.areEqual(50000, kestrel.amount.intValue(), 'amount');

        ReviewController.RowItem fundRow = rowOf(q, fundRowId);
        Assert.isTrue(fundRow.needsFund, 'fund needed');
        Assert.isTrue(fundRow.canRemember, 'an unknown spelling can be remembered');
        Assert.isFalse(fundRow.claudeAnswersIt, 'no suggestion yet');

        Assert.areEqual(1, q.followUps.size(), 'follow-up for 3390');
        ReviewController.FollowUpItem fu = q.followUps[0];
        Assert.areEqual('3390', fu.repCode, 'code');
        Assert.areEqual('Unknown Code', fu.reason, 'reason');
        Assert.areEqual(1, fu.heldRows.size(), 'held trade shown');
        Assert.areEqual('Hannah Pierce', fu.heldRows[0].advisorName, 'advisor named on the held trade');
        Assert.areEqual('The rep code is not set up for this firm', fu.heldRows[0].issue, 'why it is held');

        Assert.areEqual(3, q.firmOptions.size(), 'firms with aliases');
        Assert.areEqual(2, q.fundOptions.size(), 'funds with aliases');
        Assert.isFalse(q.claudeEnabled, 'Claude off');
        Assert.areEqual(0, q.inFlight, 'nothing running in the background');
        Assert.areEqual(1, q.recentFiles.size(), 'the batch is listed');
        Assert.areEqual(UserInfo.getUserId(), q.userId, 'current user');
    }

    @IsTest
    static void itemsWaitingForClaudeCountAsInFlight() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        reviewBatch(w);
        AiSettings.current.enabled = true;

        ReviewController.Queue q = ReviewController.getQueue('all');

        // Row 2 and the 3390 follow-up have not been asked yet; row 1 already has a suggestion.
        Assert.areEqual(2, q.inFlight, 'two items wait for Claude');
        Assert.areEqual(AiSettings.PROVIDER_MODELS_API, q.provider, 'provider shown');
    }

    @IsTest
    static void scopesFilterByAssignment() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id kestrelId = TradeTestWorld.row(batch.Id, 1).Id;

        ReviewController.setAssignment(kestrelId, true);
        ReviewController.setAssignment([SELECT Id FROM Code_Follow_Up__c].Id, true);

        ReviewController.Queue mine = ReviewController.getQueue(ReviewController.SCOPE_MINE);
        Assert.areEqual(1, mine.rows.size(), 'my row');
        Assert.areEqual(kestrelId, mine.rows[0].id, 'the Kestrel row');
        Assert.areEqual(UserInfo.getUserId(), mine.rows[0].assignedToId, 'assigned to me');
        Assert.areEqual(1, mine.followUps.size(), 'my follow-up');
        ReviewController.Queue unassigned = ReviewController.getQueue(ReviewController.SCOPE_UNASSIGNED);
        Assert.areEqual(1, unassigned.rows.size(), 'the other row');
        Assert.isNull(rowOf(unassigned, kestrelId), 'mine is not unassigned');
        Assert.areEqual(0, unassigned.followUps.size(), 'follow-up taken');
    }

    @IsTest
    static void acceptingClaudesChoiceRematchesTheRow() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id kestrelId = TradeTestWorld.row(batch.Id, 1).Id;

        Test.startTest();
        ReviewController.decideRow(kestrelId, 'Accept', null, null, null, false);
        Test.stopTest();

        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', done.Match_Status__c, 'matched');
        Assert.areEqual('Claude', done.Match_Method__c, 'Claude\'s suggestion used');
        Assert.areEqual(w.ryan.Id, done.Credited_Advisor__c, 'credited to Ryan Chen');
        Assert.areEqual(UserInfo.getUserId(), done.Decided_By__c, 'decision stamped');
    }

    @IsTest
    static void reviewersOwnFundIsUsedAndRemembered() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;

        Test.startTest();
        ReviewController.decideRow(fundRowId, 'Accept', null, w.wwfA.Id, null, true);
        Test.stopTest();

        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 2);
        Assert.areEqual('Matched', done.Match_Status__c, 'matched');
        Assert.areEqual('Reviewer', done.Match_Method__c, 'the reviewer\'s choice');
        Assert.areEqual(w.wwfA.Id, done.Matched_Fund__c, 'Series A');
        Assert.areEqual(1, [SELECT COUNT() FROM Fund_Alias__c WHERE Name = 'ETF Wealth World Fund A' AND Fund__c = :w.wwfA.Id], 'spelling remembered');
    }

    @IsTest
    static void rejectExcludesTheRow() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);

        ReviewController.decideRow(TradeTestWorld.row(batch.Id, 2).Id, 'Reject', null, null, null, false);

        Assert.areEqual('Rejected', TradeTestWorld.row(batch.Id, 2).Match_Status__c, 'rejected');
        Assert.areEqual(1, ReviewController.getQueue('all').rows.size(), 'gone from the queue');
    }

    @IsTest
    static void refusalsAreShownInTheReviewersWords() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;

        String noFund = failureOf(fundRowId, 'Accept', null, null);
        Assert.isTrue(noFund.contains('Choose a Fund Override'), 'the trigger\'s own rule: ' + noFund);
        Assert.areEqual('The decision must be Accept or Reject.', failureOf(fundRowId, 'Maybe', null, null), 'unknown decision');
        Assert.areEqual('Choose a row to decide.', failureOf(w.kesInc.Id, 'Accept', null, null), 'not a row');
        Assert.areEqual('Choose a row to decide.', failureOf(null, 'Accept', null, null), 'no row');
        Assert.areEqual('The firm must be an account.', failureOf(fundRowId, 'Accept', w.wwfA.Id, null), 'wrong record type for the firm');
        Assert.areEqual('The fund must be a product.', failureOf(fundRowId, 'Accept', null, w.kesInc.Id), 'wrong record type for the fund');

        ReviewController.decideRow(fundRowId, 'Reject', null, null, null, false);
        String twice = failureOf(fundRowId, 'Accept', null, w.wwfA.Id);
        Assert.areEqual('This row is no longer waiting for a decision. Refresh to see its current state.', twice, 'already decided');
        Assert.areEqual('Rejected', TradeTestWorld.row(batch.Id, 2).Match_Status__c, 'unchanged');
    }

    @IsTest
    static void nobodyTakesAnItemSomeoneElseHolds() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id kestrelId = TradeTestWorld.row(batch.Id, 1).Id;
        User colleague = otherUser();
        update new Import_Staging_Row__c(Id = kestrelId, Assigned_To__c = colleague.Id);

        String takeOver;
        try {
            ReviewController.setAssignment(kestrelId, true);
        } catch (AuraHandledException e) {
            takeOver = e.getMessage();
        }
        Assert.areEqual('Already assigned to Import Tester. Ask them to unassign it first.', takeOver, 'refused');
        String giveBack;
        try {
            ReviewController.setAssignment(kestrelId, false);
        } catch (AuraHandledException e) {
            giveBack = e.getMessage();
        }
        Assert.areEqual('Assigned to Import Tester. Only they can unassign it.', giveBack, 'only the assignee can unassign');
        Assert.areEqual(colleague.Id, [SELECT Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :kestrelId].Assigned_To__c, 'unchanged');

        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;
        ReviewController.setAssignment(fundRowId, true);
        ReviewController.setAssignment(fundRowId, true); // taking your own item again is harmless
        ReviewController.setAssignment(fundRowId, false);
        ReviewController.setAssignment(fundRowId, false); // and so is giving back an unassigned one
        Assert.isNull([SELECT Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :fundRowId].Assigned_To__c, 'unassigned again');

        String wrongType;
        try {
            ReviewController.setAssignment(w.kesInc.Id, true);
        } catch (AuraHandledException e) {
            wrongType = e.getMessage();
        }
        Assert.areEqual('Only review rows and follow-ups can be assigned.', wrongType, 'only rows and follow-ups');
    }

    @IsTest
    static void activatingClaudesMappingProcessesTheWaitingFile() {
        claudeOff();
        TradeTestWorld.build();
        String csv = 'Representative,Rep No.,Organisation,Security Name,Settle Date,Side,Value\nRyan Chen,1001,Kestrel Capital,Wealth World Fund - Series A,2026-09-29,B,"50,000.00"\n';
        Import_Batch__c batch = TestDataFactory.receivedBatch('KESTREL', csv);
        new ImportBatchProcessor(batch.Id).execute(null);
        batch = [SELECT Id, Header_Fingerprint__c FROM Import_Batch__c WHERE Id = :batch.Id];
        Mapping_Profile__c draft = new Mapping_Profile__c(
            Name = 'KESTREL - proposed by Claude',
            Source_Firm__c = 'KESTREL',
            Status__c = 'Draft',
            Feed_Type__c = 'Trade Activity',
            Header_Fingerprint__c = batch.Header_Fingerprint__c,
            Column_Map__c = System.JSON.serialize(
                new Map<String, String>{
                    'Representative' => 'advisorName',
                    'Rep No.' => 'repCode',
                    'Organisation' => 'firmName',
                    'Security Name' => 'fundName',
                    'Settle Date' => 'tradeDate',
                    'Side' => 'transactionType',
                    'Value' => 'amount'
                }
            ),
            Date_Format__c = 'YYYY-MM-DD',
            Decimal_Separator__c = 'Period',
            Direction_Convention__c = 'Type Column',
            AI_Rationale__c = 'Checks passed.',
            Proposed_From_Batch__c = batch.Id
        );
        insert draft;

        ReviewController.Queue before = ReviewController.getQueue('all');
        Assert.areEqual(1, before.mappings.size(), 'one file waits for a mapping');
        Assert.areEqual(draft.Id, before.mappings[0].profileId, 'with Claude\'s proposal');
        Assert.areEqual('Checks passed.', before.mappings[0].rationale, 'rationale shown');

        Test.startTest();
        ReviewController.activateMapping(draft.Id);
        Test.stopTest();

        Assert.areEqual('Active', [SELECT Status__c FROM Mapping_Profile__c WHERE Id = :draft.Id].Status__c, 'active');
        Assert.areEqual('Staged', [SELECT Status__c FROM Import_Batch__c WHERE Id = :batch.Id].Status__c, 'the waiting file was read');
        Assert.areEqual(new List<String>{ 'KESTREL' }, ReviewController.getQueue('all').sourceFirms, 'now offered for uploads');
    }

    @IsTest
    static void aMappingThatCannotBeActivatedSaysWhy() {
        claudeOff();
        Mapping_Profile__c incomplete = new Mapping_Profile__c(
            Name = 'Incomplete',
            Source_Firm__c = 'X',
            Status__c = 'Draft',
            Date_Format__c = 'YYYY-MM-DD',
            Decimal_Separator__c = 'Period',
            Direction_Convention__c = 'Type Column'
        );
        insert incomplete;
        String message;
        try {
            ReviewController.activateMapping(incomplete.Id);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Assert.isTrue(message != null && message.contains('needs a'), 'the validation rule explains: ' + message);
        Assert.areEqual('Draft', [SELECT Status__c FROM Mapping_Profile__c WHERE Id = :incomplete.Id].Status__c, 'still a draft');
    }

    @IsTest
    static void uploadedFilesEnterTheSamePipelineOnce() {
        claudeOff();
        String csv = 'Representative,Rep No.\nRyan Chen,1001\n';
        String content = EncodingUtil.base64Encode(Blob.valueOf(csv));

        Test.startTest();
        FileIntakeService.Receipt first = ReviewController.uploadFile(' harbour-1 ', 'harbour.csv', content);
        FileIntakeService.Receipt again = ReviewController.uploadFile('HARBOUR-1', 'harbour copy.csv', content);
        Test.stopTest();

        Assert.isFalse(first.duplicate, 'new file');
        Assert.isTrue(again.duplicate, 'same contents recognised');
        Assert.areEqual(first.batchId, again.batchId, 'same batch');
        Import_Batch__c batch = [SELECT Source_Firm__c, Source_File_Name__c, Status__c FROM Import_Batch__c];
        Assert.areEqual('HARBOUR-1', batch.Source_Firm__c, 'code normalised');
        Assert.areEqual('harbour.csv', batch.Source_File_Name__c, 'file name');
        Assert.areEqual('Mapping Review', batch.Status__c, 'processed: no mapping for this layout yet');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :first.batchId], 'file attached');
    }

    @IsTest
    static void badUploadsAreRefusedWithAReason() {
        claudeOff();
        Map<String, List<String>> cases = new Map<String, List<String>>{
            'Choose a file to upload.' => new List<String>{ 'BARDER', 'a.csv', '' },
            'Source firm codes may contain only' => new List<String>{ 'Barder & Co', 'a.csv', EncodingUtil.base64Encode(Blob.valueOf('a,b\n1,2\n')) },
            'A file name is required.' => new List<String>{ 'BARDER', ' ', EncodingUtil.base64Encode(Blob.valueOf('a,b\n1,2\n')) },
            'larger than 1024 KB' => new List<String>{ 'BARDER', 'a.csv', 'A'.repeat((FileIntakeService.MAX_FILE_BYTES / 3 + 1) * 4 + 4) }
        };
        for (String expected : cases.keySet()) {
            List<String> c = cases.get(expected);
            String message;
            try {
                ReviewController.uploadFile(c[0], c[1], c[2]);
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
            Assert.isTrue(message != null && message.contains(expected), expected + ' expected, got: ' + message);
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Import_Batch__c], 'nothing created');
    }

    /** The same unknown fund spelling on three Barder rows, across two files, plus one other Barder row. */
    private static List<Import_Batch__c> repeatedFundSpelling() {
        Import_Batch__c first = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_27, 1000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Zephyr Growth Pool', SEP_29, 2000)
            }
        );
        Import_Batch__c second = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'zephyr growth pool', SEP_29, 4000),
                TradeTestWorld.trade('Barder & Company', '457', 'Julia Morales', 'Unheard Of Fund', SEP_29, 8000)
            }
        );
        TradeMatcher.run(new Set<Id>{ first.Id, second.Id });
        return new List<Import_Batch__c>{ first, second };
    }

    private static ReviewController.RowItem lineFor(ReviewController.Queue q, String fundName) {
        for (ReviewController.RowItem r : q.rows) {
            if (r.fundName != null && r.fundName.equalsIgnoreCase(fundName)) {
                return r;
            }
        }
        return null;
    }

    @IsTest
    static void rowsWithTheSameIssueAreOneLineWithTheirTotals() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        List<Import_Batch__c> files = repeatedFundSpelling();

        ReviewController.Queue q = ReviewController.getQueue('all');

        Assert.areEqual(2, q.rows.size(), 'one line for the shared spelling, one for the other fund: ' + q.rows.size());
        ReviewController.RowItem shared = lineFor(q, 'Zephyr Growth Pool');
        Assert.areEqual(3, shared.groupCount, 'rows sharing the issue');
        Assert.areEqual(7000, shared.groupAmount.intValue(), 'their total');
        Assert.areEqual(2, shared.groupFileCount, 'files they came from');
        Assert.areEqual(1, lineFor(q, 'Unheard Of Fund').groupCount, 'a different spelling is its own line');
        List<ReviewController.IssueRow> rows = ReviewController.getIssueRows(shared.id);
        Assert.areEqual(3, rows.size(), 'every row is listed in the detail');
        Assert.areEqual(1, ReviewController.getIssueRows(TradeTestWorld.row(files[1].Id, 2).Id).size(), 'a single row lists itself');
        Assert.isNotNull(w, 'world built');
    }

    @IsTest
    static void oneDecisionSettlesEveryRowWithTheIssue() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        List<Import_Batch__c> files = repeatedFundSpelling();
        Id sharedId = lineFor(ReviewController.getQueue('all'), 'Zephyr Growth Pool').id;

        Test.startTest();
        Integer decided = ReviewController.decideRow(sharedId, 'Accept', null, w.wwfA.Id, null, true);
        Test.stopTest();

        Assert.areEqual(3, decided, 'all three rows decided at once');
        for (Import_Staging_Row__c r : [SELECT Match_Status__c, Matched_Fund__c FROM Import_Staging_Row__c WHERE Source_Fund_Name__c LIKE 'zephyr%']) {
            Assert.areEqual('Matched', r.Match_Status__c, 're-matched');
            Assert.areEqual(w.wwfA.Id, r.Matched_Fund__c, 'with the chosen fund');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Fund_Alias__c WHERE Fund__c = :w.wwfA.Id AND Name LIKE 'Zephyr%'], 'the spelling is remembered once');
        Assert.areEqual('Needs Review', TradeTestWorld.row(files[1].Id, 2).Match_Status__c, 'the other fund is untouched');
    }

    @IsTest
    static void bigIssuesAreDecidedInChunks() {
        claudeOff();
        TradeTestWorld.build();
        repeatedFundSpelling();
        Id sharedId = lineFor(ReviewController.getQueue('all'), 'Zephyr Growth Pool').id;
        ReviewController.MAX_BULK = 2;

        Assert.areEqual(2, ReviewController.decideRow(sharedId, 'Reject', null, null, null, false), 'one chunk at a time');
        ReviewController.RowItem rest = lineFor(ReviewController.getQueue('all'), 'Zephyr Growth Pool');
        Assert.areEqual(1, rest.groupCount, 'the rest stays in the queue');
        Assert.areEqual(1, ReviewController.decideRow(rest.id, 'Reject', null, null, null, false), 'and is decided next');
    }

    @IsTest
    static void holdingAnIssueHoldsEveryRowAndAsksTheFirmOnce() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        repeatedFundSpelling();
        juliaAnswersForBarder(w);
        Id sharedId = lineFor(ReviewController.getQueue('all'), 'Zephyr Growth Pool').id;

        Assert.areEqual(3, ReviewController.holdRow(sharedId, 'Which fund is "Zephyr Growth Pool"?'), 'all three held');
        ReviewController.Queue q = ReviewController.getQueue('all');
        Assert.areEqual(1, q.holdRows.size(), 'one On Hold line');
        Assert.areEqual(3, q.holdRows[0].groupCount, 'for three rows');
        Assert.areEqual(1, q.firmFollowUps[0].questions.size(), 'one question for the firm');
        Assert.isTrue(q.firmFollowUps[0].questions[0].source.endsWith(' · 3 rows'), 'saying how many rows: ' + q.firmFollowUps[0].questions[0].source);

        ReviewController.EmailDraft d = ReviewController.draftFirmEmail(w.barder.Id);
        Assert.isTrue(d.htmlBody.contains('3 rows across 2 files'), 'the email says how many rows: ' + d.htmlBody);
        Assert.areEqual(1, d.htmlBody.countMatches('Zephyr Growth Pool&quot;?'), 'asked once');
        Assert.areEqual(3, d.itemIds.size(), 'every row is marked when asked');

        Assert.areEqual(3, ReviewController.releaseHold(sharedId), 'released together');
        Assert.areEqual(0, ReviewController.getQueue('all').holdRows.size(), 'nothing left on hold');
    }

    @IsTest
    static void takingAnIssueNeverTakesRowsSomeoneElseHolds() {
        claudeOff();
        TradeTestWorld.build();
        repeatedFundSpelling();
        Id sharedId = lineFor(ReviewController.getQueue('all'), 'Zephyr Growth Pool').id;
        User other = otherUser();
        Import_Staging_Row__c theirs = [SELECT Id FROM Import_Staging_Row__c WHERE Source_Fund_Name__c LIKE 'zephyr%' AND Id != :sharedId LIMIT 1];
        update new Import_Staging_Row__c(Id = theirs.Id, Assigned_To__c = other.Id);

        String refused = 'no error';
        try {
            ReviewController.setAssignment(sharedId, true);
        } catch (AuraHandledException e) {
            refused = e.getMessage();
        }
        Assert.isTrue(refused.startsWith('Some rows with this issue are assigned to '), 'refused: ' + refused);
        Assert.areEqual(other.Id, [SELECT Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :theirs.Id].Assigned_To__c, 'their row is still theirs');
        Assert.areEqual(0, [SELECT COUNT() FROM Import_Staging_Row__c WHERE Assigned_To__c = :UserInfo.getUserId()], 'nothing was taken');

        update new Import_Staging_Row__c(Id = theirs.Id, Assigned_To__c = null);
        ReviewController.setAssignment(sharedId, true);
        Assert.areEqual(3, [SELECT COUNT() FROM Import_Staging_Row__c WHERE Assigned_To__c = :UserInfo.getUserId()], 'a free issue is taken whole');
        update new Import_Staging_Row__c(Id = theirs.Id, Assigned_To__c = other.Id);
        ReviewController.setAssignment(sharedId, false);
        Assert.areEqual(0, [SELECT COUNT() FROM Import_Staging_Row__c WHERE Assigned_To__c = :UserInfo.getUserId()], 'giving it back releases my rows');
        Assert.areEqual(other.Id, [SELECT Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :theirs.Id].Assigned_To__c, 'and leaves theirs alone');
    }

    @IsTest
    static void aNameThatFitsSomeTeamMembersIsChosenByAPerson() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        insert new Firm_Alias__c(Name = 'Kestrel West', Normalized_Key__c = NameNormalizer.firmKey('Kestrel West'), Firm__c = w.kesInc.Id);
        Rep_Code__c team = new Rep_Code__c(Name = 'T100', Firm__c = w.kesInc.Id);
        insert team;
        insert new List<Rep_Code_Assignment__c>{
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.ryan.Id,
                Allocation_Percent__c = 50,
                Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
            ),
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.megan.Id,
                Allocation_Percent__c = 30,
                Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
            ),
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.julia.Id,
                Allocation_Percent__c = 20,
                Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
            )
        };
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'KESTREL',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel West', 'T100', 'Chen', 'Wealth World ETF', SEP_29, 9000) }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });

        Import_Staging_Row__c row = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Needs Review', row.Match_Status__c, '"Chen" fits two of the three members: not split across all three');
        Assert.isTrue(row.Match_Flags__c.contains('ADVISOR_AMBIGUOUS'), 'flags: ' + row.Match_Flags__c);
        ReviewController.RowItem item = rowOf(ReviewController.getQueue('all'), row.Id);
        Assert.isTrue(item.needsAdvisor, 'the reviewer chooses the advisor');
        Assert.isTrue(item.isCodeIssue, 'worked in Dealer Code Review');
        Set<String> offered = new Set<String>();
        for (ReviewController.Option o : item.advisorOptions) {
            offered.add(o.label);
        }
        Assert.areEqual(new Set<String>{ 'Ryan Chen', 'Megan Chen' }, offered, 'only the members the name fits');

        String refused = failureOf(row.Id, 'Accept', null, null);
        Assert.isTrue(refused.contains('Choose the Advisor Override'), 'an advisor must be chosen: ' + refused);

        Test.startTest();
        ReviewController.decideRow(row.Id, 'Accept', null, null, w.ryan.Id, false);
        Test.stopTest();
        Import_Staging_Row__c done = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', done.Match_Status__c, 're-matched with the choice');
        Assert.areEqual(w.ryan.Id, done.Credited_Advisor__c, '100% to the chosen member');
        Assert.isTrue(done.Match_Flags__c.contains('ADVISOR_FROM_REVIEWER'), 'and says so: ' + done.Match_Flags__c);
    }

    @IsTest
    static void eachFirmInADealerFileGetsItsOwnCodeReview() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        insert new List<Firm_Alias__c>{
            new Firm_Alias__c(Name = 'Kestrel West', Normalized_Key__c = NameNormalizer.firmKey('Kestrel West'), Firm__c = w.kesInc.Id),
            new Firm_Alias__c(Name = 'Kestrel East', Normalized_Key__c = NameNormalizer.firmKey('Kestrel East'), Firm__c = w.kesLtd.Id)
        };
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'KESTREL',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Kestrel West', '9999', 'Ryan Chen', 'Wealth World ETF', SEP_29, 1000),
                TradeTestWorld.trade('Kestrel East', '9999', 'Megan Chen', 'Wealth World ETF', SEP_29, 2000)
            }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });

        Map<Id, Code_Follow_Up__c> byFirm = new Map<Id, Code_Follow_Up__c>();
        for (Code_Follow_Up__c f : [SELECT Firm__c, Held_Row_Count__c FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '9999']) {
            byFirm.put(f.Firm__c, f);
        }
        Assert.areEqual(new Set<Id>{ w.kesInc.Id, w.kesLtd.Id }, byFirm.keySet(), 'one code review per firm, not per dealer');
        Assert.areEqual(1, byFirm.get(w.kesInc.Id).Held_Row_Count__c, 'Inc. holds its own row');
        Assert.areEqual(1, byFirm.get(w.kesLtd.Id).Held_Row_Count__c, 'Ltd. holds its own row');
    }

    @IsTest
    static void codeIssuesAreSeparatedFromOtherDecisions() {
        Map<Id, List<ReviewController.Option>> none = new Map<Id, List<ReviewController.Option>>();
        ReviewController.RowItem dated = ReviewController.rowItem(
            new Import_Staging_Row__c(Match_Flags__c = 'FUND_UNRESOLVED;DATE_BEFORE_CODE_START', Row_Type__c = 'Trade', Match_Status__c = 'Needs Review'),
            none
        );
        Assert.isTrue(dated.isCodeIssue, 'any code flag sends the row to Dealer Code Review');
        Assert.areEqual('Date before code start', dated.issueType, 'the code issue names the type');
        Assert.areEqual(2, dated.issueCount, 'and the fund issue is counted');
        ReviewController.RowItem fund = ReviewController.rowItem(
            new Import_Staging_Row__c(Match_Flags__c = 'FUND_AMBIGUOUS;FIRM_FUZZY', Row_Type__c = 'Trade', Match_Status__c = 'Needs Review'),
            none
        );
        Assert.isFalse(fund.isCodeIssue, 'data issues stay in Needs Decision');
        Assert.areEqual('Fund unclear', fund.issueType, 'informational flags do not name the type');
        Assert.areEqual(1, fund.issueCount, 'only issues that need review are counted');
        ReviewController.RowItem odd = ReviewController.rowItem(
            new Import_Staging_Row__c(Match_Flags__c = 'SOMETHING_NEW', Row_Type__c = 'Trade', Match_Status__c = 'Needs Review'),
            none
        );
        Assert.areEqual('SOMETHING_NEW', odd.issueType, 'an unknown flag is shown as it is');
    }

    @IsTest
    static void flagsWithoutWordsAreShownAsThemselves() {
        Import_Staging_Row__c r = new Import_Staging_Row__c(
            Match_Flags__c = 'SOMETHING_NEW;FIRM_MISSING',
            Row_Type__c = 'Trade',
            Match_Status__c = 'Needs Review'
        );
        ReviewController.RowItem it = ReviewController.rowItem(r, new Map<Id, List<ReviewController.Option>>());
        Assert.areEqual(2, it.reasons.size(), 'one reason per flag');
        Assert.isTrue(it.reasons.contains('SOMETHING_NEW'), 'unknown flag shown as is');
        Assert.isTrue(it.reasons.contains('The file gives no firm name'), 'known flag in plain words');
        Assert.isTrue(it.needsFirm, 'a missing firm must be chosen');
        Assert.isFalse(it.canRemember, 'nothing to remember for a missing name');
        Assert.areEqual('', ReviewController.issueText(null), 'no flags, no issue');
        Assert.areEqual('NEW_THING', ReviewController.issueText('NEW_THING'), 'unknown flag as is');
    }

    /** Julia (at Barder) answers Barder's questions. */
    private static void juliaAnswersForBarder(TradeTestWorld w) {
        update new Contact(Id = w.julia.Id, Email = 'julia.ops@example.com');
        update new Account(Id = w.barder.Id, Operations_Contact__c = w.julia.Id);
    }

    @IsTest
    static void aRowOnHoldMovesToItsOwnTabUntilReleased() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;

        ReviewController.holdRow(fundRowId, '  Ask Barder which fund "ETF Wealth World Fund A" is.  ');

        ReviewController.Queue q = ReviewController.getQueue('all');
        Assert.isNull(rowOf(q, fundRowId), 'no longer in Needs Decision');
        Assert.areEqual(1, q.holdRows.size(), 'on the On Hold tab');
        ReviewController.RowItem held = q.holdRows[0];
        Assert.areEqual('Ask Barder which fund "ETF Wealth World Fund A" is.', held.holdReason, 'homework kept, trimmed');
        Assert.areEqual(UserInfo.getName(), held.heldByName, 'who held it');
        Assert.isNotNull(held.heldSince, 'when');
        Assert.areEqual(w.barder.Id, held.followUpFirmId, 'the firm to ask');

        ReviewController.releaseHold(fundRowId);
        q = ReviewController.getQueue('all');
        Assert.isNotNull(rowOf(q, fundRowId), 'back in Needs Decision');
        Assert.areEqual(0, q.holdRows.size(), 'nothing on hold');
        Import_Staging_Row__c released = [SELECT On_Hold__c, On_Hold_Reason__c FROM Import_Staging_Row__c WHERE Id = :fundRowId];
        Assert.isFalse(released.On_Hold__c, 'released');
        Assert.isNotNull(released.On_Hold_Reason__c, 'homework kept for the record');

        ReviewController.holdRow(fundRowId, 'Ask again.');
        ReviewController.decideRow(fundRowId, 'Reject', null, null, null, false);
        Import_Staging_Row__c decided = [SELECT On_Hold__c, Match_Status__c FROM Import_Staging_Row__c WHERE Id = :fundRowId];
        Assert.isFalse(decided.On_Hold__c, 'a decision takes the row off hold');
        Assert.areEqual('Rejected', decided.Match_Status__c, 'decided from the On Hold tab');
    }

    @IsTest
    static void holdNeedsAReasonAndAnOpenRow() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;
        Id heldTradeId = TradeTestWorld.row(batch.Id, 3).Id;

        String blank = 'no error';
        try {
            ReviewController.holdRow(fundRowId, '   ');
        } catch (AuraHandledException e) {
            blank = e.getMessage();
        }
        Assert.areEqual('Say what needs to be found out before putting the row on hold.', blank, 'a reason is required');

        String notOpen = 'no error';
        try {
            ReviewController.holdRow(heldTradeId, 'Ask about 3390.');
        } catch (AuraHandledException e) {
            notOpen = e.getMessage();
        }
        Assert.areEqual('Only rows waiting for a decision can be put on hold.', notOpen, 'a code-review trade is not held here');

        String wrongType = 'no error';
        try {
            ReviewController.holdRow(w.barder.Id, 'Ask.');
        } catch (AuraHandledException e) {
            wrongType = e.getMessage();
        }
        Assert.areEqual('Choose a row to put on hold.', wrongType, 'only staging rows');
        Assert.isFalse([SELECT On_Hold__c FROM Import_Staging_Row__c WHERE Id = :fundRowId].On_Hold__c, 'nothing changed');
    }

    @IsTest
    static void oneEmailPerFirmCoversHeldRowsAndCodeReviewsWithoutAmounts() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        juliaAnswersForBarder(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;
        ReviewController.holdRow(fundRowId, 'Which fund is "ETF Wealth World Fund A"?');

        ReviewController.Queue q = ReviewController.getQueue('all');
        Assert.areEqual(w.barder.Id, q.followUps[0].firmId, 'the 3390 review belongs to Barder');
        Assert.areEqual(1, q.firmFollowUps.size(), 'one firm to ask');
        ReviewController.FirmFollowUp firm = q.firmFollowUps[0];
        Assert.areEqual(w.barder.Id, firm.firmId, 'Barder');
        Assert.areEqual(2, firm.questionCount, 'the held row and the code review');
        Assert.areEqual(2, firm.notAskedCount, 'neither asked yet');
        Assert.areEqual('julia.ops@example.com', firm.contactEmail, 'goes to the Operations Contact');
        Assert.areEqual(w.julia.Id, firm.contactId, 'contact record');
        Assert.areEqual(2, firm.questions.size(), 'each question listed');
        Assert.areEqual('Which fund is "ETF Wealth World Fund A"?', firm.questions[0].text, 'held row homework');
        Assert.isTrue(firm.questions[0].source.startsWith('On hold · '), 'where it comes from: ' + firm.questions[0].source);
        Assert.areEqual('Code 3390 · Unknown Code', firm.questions[1].source, 'the code review');
        Assert.isTrue(firm.questions[1].text.startsWith('Code 3390 is not in our records.'), 'standard code question');

        ReviewController.EmailDraft d = ReviewController.draftFirmEmail(w.barder.Id);
        Assert.areEqual('julia.ops@example.com', d.toAddress, 'to the Operations Contact');
        Assert.areEqual(2, d.itemIds.size(), 'both questions');
        Assert.isFalse(d.draftedByClaude, 'Claude is off: standard list');
        Assert.isTrue(d.htmlBody.contains('Hello Julia,'), 'greets by first name: ' + d.htmlBody);
        Assert.isTrue(d.htmlBody.contains('1. Which fund is &quot;ETF Wealth World Fund A&quot;?'), 'held row homework, escaped: ' + d.htmlBody);
        Assert.isTrue(d.htmlBody.contains('Code 3390 is not in our records.'), 'standard code question: ' + d.htmlBody);
        Assert.isFalse(
            d.htmlBody.contains('12500') || d.htmlBody.contains('12,500') || d.htmlBody.contains('45000') || d.htmlBody.contains('45,000'),
            'never amounts'
        );

        ReviewController.markAsked(d.itemIds);
        q = ReviewController.getQueue('all');
        Assert.areEqual(0, q.firmFollowUps[0].notAskedCount, 'both asked');
        Assert.isNotNull(q.firmFollowUps[0].lastAskedAt, 'asked on');
        Assert.isNotNull(q.holdRows[0].askedAt, 'row shows when it was asked');
        Assert.isNotNull(q.followUps[0].askedAt, 'code review shows when it was asked');
    }

    @IsTest
    static void claudeWritesTheEmailAndTheCallIsLogged() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        juliaAnswersForBarder(w);
        FakeClaudeClient fake = FakeClaudeClient.install(
            new List<Object>{
                '{"subject": "Two questions on recent Barder files", "body": "Hi Julia,\\n\\n1. Which fund <is> it?\\n2. Who holds 3390?\\n\\nThanks"}',
                '{"subject": ""}'
            }
        );

        ReviewController.EmailDraft d = ReviewController.draftFirmEmail(w.barder.Id);
        // A JSON newline is the two characters backslash-n, hence \\n in the Apex literal above.
        Assert.isTrue(d.draftedByClaude, 'Claude drafted it: ' + [SELECT Error_Message__c FROM AI_Request_Log__c LIMIT 1]);
        Assert.areEqual('Two questions on recent Barder files', d.subject, 'Claude\'s subject');
        Assert.areEqual('<p>Hi Julia,</p><p>1. Which fund &lt;is&gt; it?<br>2. Who holds 3390?</p><p>Thanks</p>', d.htmlBody, 'escaped, paragraphs kept');
        Assert.isTrue(fake.prompts[0].contains('Never include dollar amounts'), 'told not to include amounts');
        Assert.isFalse(fake.prompts[0].contains('45000'), 'and given none');
        AI_Request_Log__c log = [SELECT Purpose__c, Status__c FROM AI_Request_Log__c ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
        Assert.areEqual(ReviewController.EMAIL_PURPOSE, log.Purpose__c, 'logged as a firm follow-up');
        Assert.areEqual('Success', log.Status__c, 'success');

        ReviewController.EmailDraft fallback = ReviewController.draftFirmEmail(w.barder.Id);
        Assert.isFalse(fallback.draftedByClaude, 'unusable answer: standard list');
        Assert.isTrue(fallback.htmlBody.contains('Code 3390 is not in our records.'), 'standard question used');
        Assert.areEqual(1, [SELECT COUNT() FROM AI_Request_Log__c WHERE Status__c = 'Invalid Response'], 'the bad answer is logged as invalid');
    }

    @IsTest
    static void theEmailNeedsAContactAndSomethingToAsk() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        String noContact = 'no error';
        try {
            ReviewController.draftFirmEmail(w.barder.Id);
        } catch (AuraHandledException e) {
            noContact = e.getMessage();
        }
        Assert.areEqual('Set the Operations Contact (with an email address) on ' + w.barder.Name + ' first.', noContact, 'contact first');

        juliaAnswersForBarder(w);
        String nothing = 'no error';
        try {
            ReviewController.draftFirmEmail(w.barder.Id);
        } catch (AuraHandledException e) {
            nothing = e.getMessage();
        }
        Assert.areEqual('Nothing is waiting for ' + w.barder.Name + '\'s answer.', nothing, 'nothing to ask');

        String wrongType = 'no error';
        try {
            ReviewController.markAsked(new List<Id>{ w.barder.Id });
        } catch (AuraHandledException e) {
            wrongType = e.getMessage();
        }
        Assert.areEqual('Only rows and code reviews can be marked as asked.', wrongType, 'only questions are marked');
    }

    @IsTest
    static void rosterRowsSayWhatApprovingWillDo() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Import_Batch__c roster = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.roster('Barder & Company', '3390', 'Hannah Pierce', 'Barder & Company - Oakville', Date.newInstance(2026, 9, 20))
            }
        );
        TradeMatcher.run(new Set<Id>{ roster.Id });
        ReviewController.Queue q = ReviewController.getQueue('all');

        ReviewController.RowItem hannah = rowOf(q, TradeTestWorld.row(roster.Id, 1).Id);
        Assert.areEqual(
            new List<String>{
                'Create advisor Hannah Pierce at ' + w.barderOakville.Name,
                'Create code 3390 at ' + w.barder.Name,
                'Assign code 3390 100% to Hannah Pierce from 2026-09-20',
                'Close the code review for 3390 and re-match its 1 held trade'
            },
            hannah.approvalPlan,
            'every record approving creates or changes'
        );
        Assert.isTrue(hannah.canApprove, 'can be approved');
        Assert.areEqual('Hannah Pierce · New advisor, new code 3390', hannah.headline, 'root cause before Claude answers');
        Assert.isNotNull(batch.Id, 'the held 3390 trade comes from the review batch');
    }

    @IsTest
    static void standardQuestionsNameTheCodeAndNeverAmounts() {
        Assert.areEqual(
            'Code 3390 is not in our records. Who holds it, at which branch, and from what date?',
            ReviewController.standardQuestion('Unknown Code', '3390'),
            'unknown'
        );
        Assert.isTrue(ReviewController.standardQuestion('Code Ended', '3102').contains('code 3102 as ended'), 'ended');
        Assert.isTrue(ReviewController.standardQuestion('Code Dormant', '5521').contains('5521'), 'dormant');
        Assert.isTrue(ReviewController.standardQuestion('Reassignment Suspected', '2210').contains('Has the code moved?'), 'reassignment');
        Assert.isTrue(ReviewController.standardQuestion('Allocation Incomplete', '8800').contains('100%'), 'allocation');
        Assert.areEqual('Please confirm the current holder of code 7700.', ReviewController.standardQuestion('Something Else', '7700'), 'anything else');
    }

    @IsTest
    static void headlinesNameTheRootCauseAndNotesAppearOnce() {
        Import_Staging_Row__c r = new Import_Staging_Row__c(
            Match_Flags__c = 'ROSTER_NEW_HOLDER',
            Row_Type__c = 'Roster',
            Match_Status__c = 'Needs Review',
            Source_Advisor_Name__c = 'Priya Nair',
            Source_Rep_Code__c = '2210',
            Match_Notes__c = 'Code 2210 is held by Marcus Lee.\nCode 2210 is held by Marcus Lee.\n\nPriya Nair is new.'
        );
        ReviewController.RowItem it = ReviewController.rowItem(r, new Map<Id, List<ReviewController.Option>>());
        Assert.areEqual('Priya Nair · Rep code mismatch on 2210', it.headline, 'root cause, by name');
        Assert.areEqual('New code holder', it.issueType, 'issue type column');
        Assert.isTrue(it.isCodeIssue, 'a roster row is worked in Dealer Code Review');
        Assert.areEqual(new List<String>{ 'Code 2210 is held by Marcus Lee.', 'Priya Nair is new.' }, it.noteLines, 'each note once');

        r.AI_Headline__c = 'Priya Nair - takes over 2210 from Marcus Lee';
        r.AI_Field_Suggestions__c = '[{"field":"Advisor","value":"Priya Nair","confidence":"High","reason":"Roster row is authoritative."}]';
        it = ReviewController.rowItem(r, new Map<Id, List<ReviewController.Option>>());
        Assert.areEqual('Priya Nair - takes over 2210 from Marcus Lee', it.headline, 'Claude\'s headline once it has answered');
        Assert.areEqual(1, it.fieldLines.size(), 'one field answer');
        Assert.areEqual('Advisor', it.fieldLines[0].field, 'field');
        Assert.areEqual('High', it.fieldLines[0].confidence, 'confidence');

        r.AI_Field_Suggestions__c = 'not json';
        Assert.areEqual(0, ReviewController.rowItem(r, new Map<Id, List<ReviewController.Option>>()).fieldLines.size(), 'a broken table shows nothing');
    }

    /**
     * A reviewer with only Trade Import Reviewer (on a Standard User profile, which has no access to this app's
     * objects) can do everything the app offers, including the background work their actions start.
     */
    @IsTest
    static void theReviewerPermissionSetIsEnough() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id kestrelId = TradeTestWorld.row(batch.Id, 1).Id;
        Import_Batch__c roster = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.roster('Barder & Company', '3390', 'Hannah Pierce', 'Barder & Company - Oakville', Date.newInstance(2026, 9, 20))
            }
        );
        TradeMatcher.run(new Set<Id>{ roster.Id });
        Id rosterRowId = TradeTestWorld.row(roster.Id, 1).Id;
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;
        juliaAnswersForBarder(w);
        User reviewer = otherUser();

        System.runAs(reviewer) {
            ReviewController.Queue q = ReviewController.getQueue('all');
            Assert.areEqual(3, q.rows.size(), 'two trade rows and the roster row are visible');
            Test.startTest();
            ReviewController.setAssignment(kestrelId, true);
            ReviewController.decideRow(kestrelId, 'Accept', null, null, null, false);
            ReviewController.decideRow(rosterRowId, 'Accept', null, null, null, false);
            ReviewController.uploadFile('HARBOUR', 'harbour.csv', EncodingUtil.base64Encode(Blob.valueOf('Representative,Rep No.\nRyan Chen,1001\n')));
            ReviewController.holdRow(fundRowId, 'Which fund is it?');
            ReviewController.EmailDraft d = ReviewController.draftFirmEmail(w.barder.Id);
            ReviewController.markAsked(d.itemIds);
            ReviewController.releaseHold(fundRowId);
            Test.stopTest();
        }

        Import_Staging_Row__c kestrel = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Matched', kestrel.Match_Status__c, 're-matched by the reviewer\'s own job');
        Assert.areEqual(reviewer.Id, kestrel.Decided_By__c, 'decided by the reviewer');
        Assert.areEqual(reviewer.Id, [SELECT Assigned_To__c FROM Import_Staging_Row__c WHERE Id = :kestrelId].Assigned_To__c, 'assigned to the reviewer');
        Contact hannah = [SELECT AccountId FROM Contact WHERE LastName = 'Pierce'];
        Assert.areEqual(w.barderOakville.Id, hannah.AccountId, 'roster approval created the advisor');
        Assert.areEqual(1, [SELECT COUNT() FROM Rep_Code_Assignment__c WHERE Advisor__c = :hannah.Id], 'and her assignment');
        Assert.areEqual('Resolved', [SELECT Status__c FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '3390'].Status__c, 'and resolved the follow-up');
        Assert.areEqual(
            'Mapping Review',
            [SELECT Status__c FROM Import_Batch__c WHERE Source_Firm__c = 'HARBOUR'].Status__c,
            'the upload was processed as the reviewer'
        );
        Import_Staging_Row__c fundRow = [SELECT On_Hold__c, On_Hold_By__c, Asked_Firm_At__c FROM Import_Staging_Row__c WHERE Id = :fundRowId];
        Assert.areEqual(reviewer.Id, fundRow.On_Hold_By__c, 'held by the reviewer');
        Assert.isFalse(fundRow.On_Hold__c, 'and released');
        Assert.isNotNull(fundRow.Asked_Firm_At__c, 'marked as asked');
    }

    /** Team code T200 at Kestrel Inc.: Ryan 50% and Megan 30% (80%), so unnamed rows are held as Allocation Incomplete. */
    private static Import_Batch__c incompleteTeam(TradeTestWorld w) {
        insert new Firm_Alias__c(Name = 'Kestrel West', Normalized_Key__c = NameNormalizer.firmKey('Kestrel West'), Firm__c = w.kesInc.Id);
        Rep_Code__c team = new Rep_Code__c(Name = 'T200', Firm__c = w.kesInc.Id);
        insert team;
        insert new List<Rep_Code_Assignment__c>{
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.ryan.Id,
                Allocation_Percent__c = 50,
                Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
            ),
            new Rep_Code_Assignment__c(
                Rep_Code__c = team.Id,
                Advisor__c = w.megan.Id,
                Allocation_Percent__c = 30,
                Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
            )
        };
        Import_Staging_Row__c aum = TradeTestWorld.trade('Kestrel West', 'T200', null, 'Wealth World ETF', SEP_29, 50000);
        aum.Row_Type__c = 'AUM';
        aum.Transaction_Type__c = null;
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'KESTREL',
            new List<Import_Staging_Row__c>{ TradeTestWorld.trade('Kestrel West', 'T200', null, 'Wealth World ETF', SEP_27, 9000), aum }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        return batch;
    }

    private static ReviewController.FollowUpItem followUpOf(ReviewController.Queue q, Id followUpId) {
        for (ReviewController.FollowUpItem f : q.followUps) {
            if (f.id == followUpId) {
                return f;
            }
        }
        return null;
    }

    private static String creditFailure(Id followUpId, Id advisorId) {
        try {
            ReviewController.creditCodeReview(followUpId, advisorId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }

    @IsTest
    static void aCodeReviewIsSettledByCreditingOneAdvisor() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = incompleteTeam(w);
        Code_Follow_Up__c fu = [SELECT Id, Reason__c FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = 'T200'];
        Assert.areEqual('Allocation Incomplete', fu.Reason__c, 'held behind the incomplete split');
        // Claude answered but could not choose between the two members.
        update new Code_Follow_Up__c(
            Id = fu.Id,
            AI_Status__c = 'Suggested',
            AI_Field_Suggestions__c = '[{"field":"Advisor","value":null,"confidence":"Low","reason":"Nothing names either member."}]'
        );
        User reviewer = otherUser();

        System.runAs(reviewer) {
            ReviewController.FollowUpItem item = followUpOf(ReviewController.getQueue('all'), fu.Id);
            Assert.areEqual(2, item.heldRowCount, 'a trade and an AUM balance are held');
            Assert.areEqual(1, item.tradeCount, 'one trade');
            Assert.areEqual(1, item.aumCount, 'one AUM balance');
            Assert.areEqual(9000, item.heldAmount.intValue(), 'the held amount counts the trade only');
            Assert.areEqual(50000, item.aumAmount.intValue(), 'the AUM balance is counted apart');
            Set<String> types = new Set<String>();
            for (ReviewController.HeldRow h : item.heldRows) {
                types.add(h.rowType);
            }
            Assert.areEqual(new Set<String>{ 'Trade', 'AUM' }, types, 'each held row says what it is');
            Assert.isTrue(item.heldIssue.contains('100%'), 'why they are held: ' + item.heldIssue);
            List<String> offered = new List<String>();
            for (ReviewController.Option o : item.advisorOptions) {
                offered.add(o.label);
            }
            Assert.areEqual(new List<String>{ 'Megan Chen', 'Ryan Chen' }, offered, 'the members holding the code on every held date');
            Assert.areEqual('Megan Chen or Ryan Chen', item.fieldLines[0].value, 'Claude left it open: the choices are shown');
            Assert.isTrue(item.fieldLines[0].openQuestion, 'and marked as open');

            String refused = creditFailure(fu.Id, w.julia.Id);
            Assert.isTrue(refused.contains('did not hold code T200'), 'only someone holding the code: ' + refused);

            Test.startTest();
            Assert.areEqual(2, ReviewController.creditCodeReview(fu.Id, w.ryan.Id), 'both held rows credited');
            Test.stopTest();

            String again = creditFailure(fu.Id, w.ryan.Id);
            Assert.isTrue(again.contains('already closed'), 'a closed review cannot be settled twice: ' + again);
        }

        Code_Follow_Up__c done = [SELECT Status__c, Resolution_Notes__c FROM Code_Follow_Up__c WHERE Id = :fu.Id];
        Assert.areEqual('Resolved', done.Status__c, 'resolved');
        Assert.isTrue(done.Resolution_Notes__c.startsWith('Credited Ryan Chen for 2 held rows'), 'and noted: ' + done.Resolution_Notes__c);
        for (Import_Staging_Row__c r : TradeTestWorld.rowsOf(batch.Id).values()) {
            Assert.areEqual('Matched', r.Match_Status__c, 'row ' + r.Row_Number__c + ' re-matched: ' + r.Match_Flags__c);
            Assert.areEqual(w.ryan.Id, r.Credited_Advisor__c, 'row ' + r.Row_Number__c + ' credited 100% to Ryan');
            Assert.areEqual(reviewer.Id, r.Decided_By__c, 'row ' + r.Row_Number__c + ' records who chose');
            Assert.isTrue(r.Match_Flags__c.contains('ADVISOR_FROM_REVIEWER'), 'and says a reviewer chose: ' + r.Match_Flags__c);
        }
    }

    @IsTest
    static void aCodeReviewCanBeRematchedOrSentToNeedsDecision() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = TradeTestWorld.stagedBatch(
            'BARDER',
            new List<Import_Staging_Row__c>{
                TradeTestWorld.trade('Barder & Company', '7001', 'Julia Morales', 'Wealth World ETF', SEP_29, 1000),
                TradeTestWorld.trade('Barder & Company', '7002', 'Julia Morales', 'Wealth World ETF', SEP_29, 2000)
            }
        );
        TradeMatcher.run(new Set<Id>{ batch.Id });
        Code_Follow_Up__c unfixable = [SELECT Id FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '7001'];
        Code_Follow_Up__c fixable = [SELECT Id FROM Code_Follow_Up__c WHERE Rep_Code_Value__c = '7002'];
        update new Code_Follow_Up__c(
            Id = unfixable.Id,
            AI_Status__c = 'Suggested',
            AI_Field_Suggestions__c = '[{"field":"Advisor","value":null,"confidence":"Low","reason":"The code is not set up."}]'
        );

        ReviewController.FollowUpItem item = followUpOf(ReviewController.getQueue('all'), unfixable.Id);
        Assert.isTrue(item.advisorOptions.isEmpty(), 'an unknown code has nobody to credit');
        Assert.areEqual('Ask the firm', item.fieldLines[0].value, 'with no choices to list, the firm is asked');
        String refused = creditFailure(unfixable.Id, w.julia.Id);
        Assert.isTrue(refused.contains('cannot be settled by crediting'), 'refused: ' + refused);

        Assert.areEqual(1, ReviewController.closeCodeReview(unfixable.Id, false), 'one row was waiting');
        Import_Staging_Row__c sent = TradeTestWorld.row(batch.Id, 1);
        Assert.areEqual('Needs Review', sent.Match_Status__c, 'sent to Needs Decision');
        Assert.isTrue(sent.Match_Flags__c.contains('FOLLOW_UP_CLOSED'), 'and says why: ' + sent.Match_Flags__c);
        Assert.areEqual('Closed - No Action', [SELECT Status__c FROM Code_Follow_Up__c WHERE Id = :unfixable.Id].Status__c, 'closed');

        // The code is set up in Salesforce, then re-matched from the app.
        Rep_Code__c code = new Rep_Code__c(Name = '7002', Firm__c = w.barder.Id);
        insert code;
        insert new Rep_Code_Assignment__c(
            Rep_Code__c = code.Id,
            Advisor__c = w.julia.Id,
            Allocation_Percent__c = 100,
            Effective_Start_Date__c = Date.newInstance(2026, 1, 1)
        );
        Test.startTest();
        ReviewController.closeCodeReview(fixable.Id, true);
        Test.stopTest();
        Import_Staging_Row__c rematched = TradeTestWorld.row(batch.Id, 2);
        Assert.areEqual('Matched', rematched.Match_Status__c, 're-matched against the fixed code: ' + rematched.Match_Flags__c);
        Assert.areEqual(w.julia.Id, rematched.Credited_Advisor__c, 'credited to the code holder');
        Assert.isTrue(
            [SELECT Resolution_Notes__c FROM Code_Follow_Up__c WHERE Id = :fixable.Id].Resolution_Notes__c.startsWith('Re-matched 1 held row after'),
            'noted'
        );
    }

    @IsTest
    static void openChoicesAreListedByName() {
        Assert.areEqual('A', ReviewController.choiceText(new List<String>{ 'A' }), 'one');
        Assert.areEqual('A or B', ReviewController.choiceText(new List<String>{ 'A', 'B' }), 'two');
        Assert.areEqual('A, B or C', ReviewController.choiceText(new List<String>{ 'A', 'B', 'C' }), 'three');
        Assert.areEqual('A, B, C or 2 more', ReviewController.choiceText(new List<String>{ 'A', 'B', 'C', 'D', 'E' }), 'five');

        Map<String, List<String>> names = ReviewController.candidateNames(
            '[{"type":"fund","name":"Series A"},{"type":"fund","name":"Series F"},{"type":"fund","name":"Series A"},' +
            '{"type":"firm","name":"Kestrel"},{"type":"other","name":"Q"},{"type":"advisor"}]'
        );
        Assert.areEqual(new List<String>{ 'Series A', 'Series F' }, names.get('Fund'), 'funds, once each');
        Assert.areEqual(new List<String>{ 'Kestrel' }, names.get('Firm'), 'firms');
        Assert.isFalse(names.containsKey('Advisor'), 'a candidate without a name is skipped');
        Assert.areEqual(2, names.size(), 'unknown types are skipped');
        Assert.isTrue(ReviewController.candidateNames('not json').isEmpty(), 'malformed gives nothing');
        Assert.isTrue(ReviewController.candidateNames(null).isEmpty(), 'blank gives nothing');
    }

    @IsTest
    static void aFundClaudeLeftOpenShowsTheFundsItWeighed() {
        claudeOff();
        TradeTestWorld w = TradeTestWorld.build();
        Import_Batch__c batch = reviewBatch(w);
        Id fundRowId = TradeTestWorld.row(batch.Id, 2).Id;
        update new Import_Staging_Row__c(
            Id = fundRowId,
            Match_Candidates__c = '[{"type":"fund","id":"' +
                w.wwfA.Id +
                '","name":"Wealth World Fund - Series A"},{"type":"fund","id":"' +
                w.wwEtf.Id +
                '","name":"Wealth World ETF"}]',
            AI_Status__c = 'Suggested',
            AI_Field_Suggestions__c = '[{"field":"Fund","value":null,"confidence":"Low","reason":"The name fits both."},' +
                '{"field":"Firm","value":"Barder & Company","confidence":"High","reason":"Known."}]'
        );

        ReviewController.RowItem item = rowOf(ReviewController.getQueue('all'), fundRowId);
        Assert.areEqual('Wealth World Fund - Series A or Wealth World ETF', item.fieldLines[0].value, 'the funds weighed');
        Assert.isTrue(item.fieldLines[0].openQuestion, 'marked as open');
        Assert.areEqual('Barder & Company', item.fieldLines[1].value, 'an answer is shown as given');
        Assert.isFalse(item.fieldLines[1].openQuestion, 'and is not open');
    }
}
