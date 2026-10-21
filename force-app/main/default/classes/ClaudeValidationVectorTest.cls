// Generated from tools/verify/gen_tests3b.py; the same vectors are checked against a Python port before delivery.
// Claude's answers are untrusted input: these cases pin down exactly what is accepted, ignored or rejected.
@IsTest
private class ClaudeValidationVectorTest {
    private static ClaudeSuggestionService.Item item(String key, List<String> asks, Map<String, List<String>> allowed) {
        ClaudeSuggestionService.Item it = new ClaudeSuggestionService.Item();
        it.key = key;
        it.asks = new Set<String>(asks);
        for (String a : allowed.keySet()) {
            it.allowed.put(a, new Set<String>(allowed.get(a)));
        }
        return it;
    }

    private static List<String> sorted(Set<String> values) {
        List<String> result = new List<String>(values);
        result.sort();
        return result;
    }

    private static List<String> sorted(List<String> values) {
        List<String> result = new List<String>(values);
        result.sort();
        return result;
    }

    private static void expectSuggestion(ClaudeSuggestionService.Validation v, String vector, String key, String firm, String fund, String advisor,
                                         String recommendation, String confidence, String explanation, Integer explanationLength) {
        ClaudeSuggestionService.Suggestion s = v.byItem.get(key);
        String context = vector + ' ' + key + ': ';
        Assert.areEqual(firm, s.firm, context + 'firm');
        Assert.areEqual(fund, s.fund, context + 'fund');
        Assert.areEqual(advisor, s.advisor, context + 'advisor');
        Assert.areEqual(recommendation, s.recommendation, context + 'recommendation');
        Assert.areEqual(confidence, s.confidence, context + 'confidence');
        Assert.areEqual(explanationLength, s.explanation.length(), context + 'explanation length');
        if (explanation != null) {
            Assert.areEqual(explanation, s.explanation, context + 'explanation');
        }
    }

    private static void assertParseFails(String text, String expectedStart, String vector) {
        try {
            ClaudeService.parseObject(text);
            Assert.fail(vector + ': expected a ClaudeException');
        } catch (ClaudeService.ClaudeException e) {
            Assert.isTrue(e.getMessage().startsWith(expectedStart), vector + ': ' + e.getMessage());
        }
    }

    @IsTest
    static void suggestionResponsesMatchVectors() {
        Map<String, ClaudeSuggestionService.Item> items = new Map<String, ClaudeSuggestionService.Item>();
        items.put('R1', item('R1', new List<String>{ 'firm' }, new Map<String, List<String>>{ 'firm' => new List<String>{ 'F1', 'F2' } }));
        items.put('R2', item('R2', new List<String>{ 'fund' }, new Map<String, List<String>>{ 'fund' => new List<String>{ 'P1', 'P2', 'P3' } }));
        items.put('R3', item('R3', new List<String>{ 'advisor', 'recommendation' }, new Map<String, List<String>>{ 'advisor' => new List<String>{ 'A1', 'A2' } }));
        items.put('U1', item('U1', new List<String>{ 'advisor' }, new Map<String, List<String>>{ 'advisor' => new List<String>{ 'A3' } }));
        ClaudeSuggestionService.Validation v;
        // all valid in a code fence
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('```json\n{"suggestions": [{"item": "R1", "firm": "F2", "confidence": "High", "explanation": "Evidence."}, {"item": "R2", "fund": "P1", "confidence": "Medium", "explanation": "Evidence."}, {"item": "R3", "advisor": "A1", "recommendation": "Approve", "confidence": "High", "explanation": "Evidence."}, {"item": "U1", "advisor": null, "confidence": "low", "explanation": "Not in Salesforce yet."}]}\n```'), items);
        Assert.areEqual(true, v.usable, 'all valid in a code fence: usable');
        Assert.areEqual(new List<String>{ 'R1', 'R2', 'R3', 'U1' }, sorted(v.byItem.keySet()), 'all valid in a code fence: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'all valid in a code fence: invalid items');
        Assert.areEqual(new List<String>(), sorted(v.problems), 'all valid in a code fence: problems');
        expectSuggestion(v, 'all valid in a code fence', 'R1', 'F2', null, null, null, 'High', 'Evidence.', 9);
        expectSuggestion(v, 'all valid in a code fence', 'R2', null, 'P1', null, null, 'Medium', 'Evidence.', 9);
        expectSuggestion(v, 'all valid in a code fence', 'R3', null, null, 'A1', 'approve', 'High', 'Evidence.', 9);
        expectSuggestion(v, 'all valid in a code fence', 'U1', null, null, null, null, 'Low', 'Not in Salesforce yet.', 22);
        // invented firm key
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": "F9", "confidence": "High", "explanation": "Evidence."}, {"item": "R2", "fund": "P3", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'invented firm key: usable');
        Assert.areEqual(new List<String>{ 'R2' }, sorted(v.byItem.keySet()), 'invented firm key: suggested items');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.invalidItems), 'invented firm key: invalid items');
        Assert.areEqual(new List<String>{ 'Item R1: firm "F9" is not one of the candidates sent.' }, sorted(v.problems), 'invented firm key: problems');
        expectSuggestion(v, 'invented firm key', 'R2', null, 'P3', null, null, 'High', 'Evidence.', 9);
        // unknown and duplicate items
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R9", "firm": "F1", "confidence": "High", "explanation": "Evidence."}, {"item": "R1", "firm": "F1", "confidence": "High", "explanation": "Evidence."}, {"item": "R1", "firm": "F2", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'unknown and duplicate items: usable');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.byItem.keySet()), 'unknown and duplicate items: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'unknown and duplicate items: invalid items');
        Assert.areEqual(new List<String>{ 'Entry 1 refers to an unknown item: R9.', 'Item R1 appears more than once; only the first entry is used.' }, sorted(v.problems), 'unknown and duplicate items: problems');
        expectSuggestion(v, 'unknown and duplicate items', 'R1', 'F1', null, null, null, 'High', 'Evidence.', 9);
        // bad confidence and lower case
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": "F1", "confidence": "Sure", "explanation": "Evidence."}, {"item": "R2", "fund": "P2", "confidence": " medium ", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'bad confidence and lower case: usable');
        Assert.areEqual(new List<String>{ 'R2' }, sorted(v.byItem.keySet()), 'bad confidence and lower case: suggested items');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.invalidItems), 'bad confidence and lower case: invalid items');
        Assert.areEqual(new List<String>{ 'Item R1: confidence must be High, Medium or Low.' }, sorted(v.problems), 'bad confidence and lower case: problems');
        expectSuggestion(v, 'bad confidence and lower case', 'R2', null, 'P2', null, null, 'Medium', 'Evidence.', 9);
        // missing or blank explanation
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": "F1", "confidence": "High"}, {"item": "R2", "fund": "P2", "confidence": "High", "explanation": "   "}]}'), items);
        Assert.areEqual(true, v.usable, 'missing or blank explanation: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'missing or blank explanation: suggested items');
        Assert.areEqual(new List<String>{ 'R1', 'R2' }, sorted(v.invalidItems), 'missing or blank explanation: invalid items');
        Assert.areEqual(new List<String>{ 'Item R1: explanation is required.', 'Item R2: explanation is required.' }, sorted(v.problems), 'missing or blank explanation: problems');

        // unasked fields ignored
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R2", "fund": "P2", "firm": "F1", "advisor": "A9", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'unasked fields ignored: usable');
        Assert.areEqual(new List<String>{ 'R2' }, sorted(v.byItem.keySet()), 'unasked fields ignored: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'unasked fields ignored: invalid items');
        Assert.areEqual(new List<String>(), sorted(v.problems), 'unasked fields ignored: problems');
        expectSuggestion(v, 'unasked fields ignored', 'R2', null, 'P2', null, null, 'High', 'Evidence.', 9);
        // bad recommendation
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R3", "recommendation": "maybe", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'bad recommendation: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'bad recommendation: suggested items');
        Assert.areEqual(new List<String>{ 'R3' }, sorted(v.invalidItems), 'bad recommendation: invalid items');
        Assert.areEqual(new List<String>{ 'Item R3: recommendation must be approve, reject or unsure.' }, sorted(v.problems), 'bad recommendation: problems');

        // recommendation not asked is ignored
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": "F1", "recommendation": "whatever", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'recommendation not asked is ignored: usable');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.byItem.keySet()), 'recommendation not asked is ignored: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'recommendation not asked is ignored: invalid items');
        Assert.areEqual(new List<String>(), sorted(v.problems), 'recommendation not asked is ignored: problems');
        expectSuggestion(v, 'recommendation not asked is ignored', 'R1', 'F1', null, null, null, 'High', 'Evidence.', 9);
        // no suggestions key
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"answer": []}'), items);
        Assert.areEqual(false, v.usable, 'no suggestions key: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'no suggestions key: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'no suggestions key: invalid items');
        Assert.areEqual(new List<String>{ 'The response has no "suggestions" list.' }, sorted(v.problems), 'no suggestions key: problems');

        // suggestions is not a list
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": {"item": "R1"}}'), items);
        Assert.areEqual(false, v.usable, 'suggestions is not a list: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'suggestions is not a list: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'suggestions is not a list: invalid items');
        Assert.areEqual(new List<String>{ 'The response has no "suggestions" list.' }, sorted(v.problems), 'suggestions is not a list: problems');

        // entry is not an object
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": ["R1", {"item": "R2", "fund": "P1", "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'entry is not an object: usable');
        Assert.areEqual(new List<String>{ 'R2' }, sorted(v.byItem.keySet()), 'entry is not an object: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'entry is not an object: invalid items');
        Assert.areEqual(new List<String>{ 'Entry 1 is not an object.' }, sorted(v.problems), 'entry is not an object: problems');
        expectSuggestion(v, 'entry is not an object', 'R2', null, 'P1', null, null, 'High', 'Evidence.', 9);
        // numeric and null item
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": 5, "confidence": "High", "explanation": "x"}, {"item": null}]}'), items);
        Assert.areEqual(true, v.usable, 'numeric and null item: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'numeric and null item: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'numeric and null item: invalid items');
        Assert.areEqual(new List<String>{ 'Entry 1 refers to an unknown item: 5.', 'Entry 2 refers to an unknown item: null.' }, sorted(v.problems), 'numeric and null item: problems');

        // firm given as a number
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": 3, "confidence": "High", "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'firm given as a number: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'firm given as a number: suggested items');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.invalidItems), 'firm given as a number: invalid items');
        Assert.areEqual(new List<String>{ 'Item R1: firm must be a key or null.' }, sorted(v.problems), 'firm given as a number: problems');

        // long explanation is shortened
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "U1", "advisor": "A3", "confidence": "High", "explanation": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}]}'), items);
        Assert.areEqual(true, v.usable, 'long explanation is shortened: usable');
        Assert.areEqual(new List<String>{ 'U1' }, sorted(v.byItem.keySet()), 'long explanation is shortened: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'long explanation is shortened: invalid items');
        Assert.areEqual(new List<String>(), sorted(v.problems), 'long explanation is shortened: problems');
        expectSuggestion(v, 'long explanation is shortened', 'U1', null, null, 'A3', null, 'High', null, 2000);
        // confidence not text
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('{"suggestions": [{"item": "R1", "firm": "F1", "confidence": true, "explanation": "Evidence."}]}'), items);
        Assert.areEqual(true, v.usable, 'confidence not text: usable');
        Assert.areEqual(new List<String>(), sorted(v.byItem.keySet()), 'confidence not text: suggested items');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.invalidItems), 'confidence not text: invalid items');
        Assert.areEqual(new List<String>{ 'Item R1: confidence must be High, Medium or Low.' }, sorted(v.problems), 'confidence not text: problems');

        // prose around the JSON
        v = ClaudeSuggestionService.validate(ClaudeService.parseObject('Here is my answer:\n{"suggestions": [{"item": "R1", "firm": "F1", "confidence": "High", "explanation": "Evidence."}]}\nLet me know if you need more.'), items);
        Assert.areEqual(true, v.usable, 'prose around the JSON: usable');
        Assert.areEqual(new List<String>{ 'R1' }, sorted(v.byItem.keySet()), 'prose around the JSON: suggested items');
        Assert.areEqual(new List<String>(), sorted(v.invalidItems), 'prose around the JSON: invalid items');
        Assert.areEqual(new List<String>(), sorted(v.problems), 'prose around the JSON: problems');
        expectSuggestion(v, 'prose around the JSON', 'R1', 'F1', null, null, null, 'High', 'Evidence.', 9);
    }

    @IsTest
    static void unparseableResponsesAreRejected() {
        assertParseFails('I cannot help with that.', 'The response contains no JSON object.', 'no JSON');
        assertParseFails('} {', 'The response contains no JSON object.', 'braces reversed');
        assertParseFails('{"suggestions": [{"item": "R1"', 'The response contains no JSON object.', 'truncated JSON');
        assertParseFails('{"suggestions": [oops]}', 'The response is not valid JSON', 'invalid JSON');
        assertParseFails(null, 'The response contains no JSON object.', 'null');
    }

    @IsTest
    static void explanationsNeverShowKeys() {
        Map<String, String> names = new Map<String, String>{ 'F1' => 'Kestrel Capital Inc.', 'P3' => 'Wealth World ETF', 'P5' => 'Wealth World Fund - Series F', 'A1' => 'Julia Morales', 'A2' => '', 'R1' => 'row ISR-0000012', 'U1' => 'the 3390 follow-up' };
        Assert.areEqual('the \'Fund A\' portion aligns with Series A rather than the Wealth World ETF or Series F, so a reviewer should confirm.', ClaudeSuggestionService.readable('the \'Fund A\' portion aligns with Series A rather than the Wealth World ETF (P3) or Series F (P5), so a reviewer should confirm.', names), 'live run 2026-10-19');
        Assert.areEqual('It is not one of the ETFs.', ClaudeSuggestionService.readable('It is not one of the ETFs (P3 or P5).', names), 'bracketed list');
        Assert.areEqual('Two candidates fit.', ClaudeSuggestionService.readable('Two candidates (P3, P5) fit.', names), 'bracketed comma list');
        Assert.areEqual('Suggest Kestrel Capital Inc. for row ISR-0000012.', ClaudeSuggestionService.readable('Suggest F1 for R1.', names), 'bare keys');
        Assert.areEqual('the 3390 follow-up can be closed once Julia Morales confirms.', ClaudeSuggestionService.readable('U1 can be closed once A1 confirms.', names), 'item key');
        Assert.areEqual('Code P9 and (P9) are not ours.', ClaudeSuggestionService.readable('Code P9 and (P9) are not ours.', names), 'unknown keys untouched');
        Assert.areEqual('Fund (Wealth World ETF, P9).', ClaudeSuggestionService.readable('Fund (P3, P9).', names), 'bracket with an unknown key keeps brackets');
        Assert.areEqual('Codes A12X, XA1 and Julia Morales.', ClaudeSuggestionService.readable('Codes A12X, XA1 and A1.', names), 'word edges');
        Assert.areEqual('A2 is unnamed (A2).', ClaudeSuggestionService.readable('A2 is unnamed (A2).', names), 'blank name untouched');
        Assert.areEqual('p3 is not a key.', ClaudeSuggestionService.readable('p3 is not a key.', names), 'lower case untouched');
        Assert.areEqual('Plain text with no keys.', ClaudeSuggestionService.readable('Plain text with no keys.', names), 'no keys');
        Assert.areEqual('holds the code.', ClaudeSuggestionService.readable('(F1) holds the code.', names), 'bracket at start');
        Assert.areEqual('Kestrel Capital Inc. fits.', ClaudeSuggestionService.readable('Kestrel Capital Inc. (F1)(P3) fits.', names), 'adjacent brackets');
        Assert.areEqual('Neither fund fits.', ClaudeSuggestionService.readable('Neither fund (F1 and P3) fits.', names), 'bracketed and-list');
        Assert.areEqual(('x'.repeat(1995) + ' Wealth World ETF').left(1997) + '...', ClaudeSuggestionService.readable('x'.repeat(1995) + ' P3', names), 'long text is capped');
        Assert.areEqual('F1', ClaudeSuggestionService.readable('F1', new Map<String, String>()), 'no names: unchanged');
        Assert.isNull(ClaudeSuggestionService.readable(null, names), 'null stays null');
    }

    @IsTest
    static void mappingProposalsMatchVectors() {
        List<String> headers = new List<String>{ 'Representative', 'Rep No.', 'Organisation', 'Security Name', 'Settle Date', 'Side', 'Value' };
        List<String> problems;
        MappingProposalService.Proposal p;
        // valid Kestrel proposal
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>(), sorted(problems), 'valid Kestrel proposal: problems');
        Assert.areEqual(new Map<String, String>{ 'Representative' => 'advisorName', 'Rep No.' => 'repCode', 'Organisation' => 'firmName', 'Security Name' => 'fundName', 'Settle Date' => 'tradeDate', 'Side' => 'transactionType', 'Value' => 'amount' }, p.columnMap, 'valid Kestrel proposal: column map');
        Assert.areEqual('Trade Activity', p.feedType, 'valid Kestrel proposal: feed type');
        Assert.areEqual('YYYY-MM-DD', p.dateFormat, 'valid Kestrel proposal: date format');
        Assert.areEqual(null, p.aumIndicatorValues, 'valid Kestrel proposal: AUM indicators');
        Assert.areEqual('High', p.confidence, 'valid Kestrel proposal: confidence');
        // headers matched loosely
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"  rep no. ": "repCode", "REPRESENTATIVE": "advisorName", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>(), sorted(problems), 'headers matched loosely: problems');
        Assert.areEqual(new Map<String, String>{ 'Rep No.' => 'repCode', 'Representative' => 'advisorName', 'Organisation' => 'firmName', 'Security Name' => 'fundName', 'Settle Date' => 'tradeDate', 'Side' => 'transactionType', 'Value' => 'amount' }, p.columnMap, 'headers matched loosely: column map');
        Assert.areEqual('Trade Activity', p.feedType, 'headers matched loosely: feed type');
        Assert.areEqual('YYYY-MM-DD', p.dateFormat, 'headers matched loosely: date format');
        Assert.areEqual(null, p.aumIndicatorValues, 'headers matched loosely: AUM indicators');
        Assert.areEqual('High', p.confidence, 'headers matched loosely: confidence');
        // extra and missing columns
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Units": "IGNORE"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'Column "Value" has no mapping.', 'columnMap names a column that is not in the file: "Units".' }, sorted(problems), 'extra and missing columns: problems');
        Assert.isNull(p, 'extra and missing columns: no proposal');
        // unknown field
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "units"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'Column "Value" is mapped to units, which is not a known field.' }, sorted(problems), 'unknown field: problems');
        Assert.isNull(p, 'unknown field: no proposal');
        // same column twice
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount", "rep no.": "IGNORE"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'Column "Rep No." is mapped more than once.' }, sorted(problems), 'same column twice: problems');
        Assert.isNull(p, 'same column twice: no proposal');
        // bad settings
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trades", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "DD-MM-YYYY", "decimalSeparator": "Dot", "directionConvention": null, "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'dateFormat must be one of: DD/MM/YYYY, MM/DD/YYYY, YYYY-MM-DD.', 'decimalSeparator must be one of: Comma, Period.', 'directionConvention must be one of: Signed Amount, Type Column.', 'feedType must be one of: Advisor Code Roster, Trade Activity.' }, sorted(problems), 'bad settings: problems');
        Assert.isNull(p, 'bad settings: no proposal');
        // AUM indicator as number
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": 5, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'aumIndicatorValues must be text or null.' }, sorted(problems), 'AUM indicator as number: problems');
        Assert.isNull(p, 'AUM indicator as number: no proposal');
        // blank AUM indicator becomes null
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": "  ", "confidence": "medium", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>(), sorted(problems), 'blank AUM indicator becomes null: problems');
        Assert.areEqual(new Map<String, String>{ 'Representative' => 'advisorName', 'Rep No.' => 'repCode', 'Organisation' => 'firmName', 'Security Name' => 'fundName', 'Settle Date' => 'tradeDate', 'Side' => 'transactionType', 'Value' => 'amount' }, p.columnMap, 'blank AUM indicator becomes null: column map');
        Assert.areEqual('Trade Activity', p.feedType, 'blank AUM indicator becomes null: feed type');
        Assert.areEqual('YYYY-MM-DD', p.dateFormat, 'blank AUM indicator becomes null: date format');
        Assert.areEqual(null, p.aumIndicatorValues, 'blank AUM indicator becomes null: AUM indicators');
        Assert.areEqual('Medium', p.confidence, 'blank AUM indicator becomes null: confidence');
        // column map not an object
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": ["Rep No."], "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": "High", "explanation": "Side holds B or S."}'), headers, problems);
        Assert.areEqual(new List<String>{ 'columnMap must be an object of "column header": "field".' }, sorted(problems), 'column map not an object: problems');
        Assert.isNull(p, 'column map not an object: no proposal');
        // missing confidence and explanation
        problems = new List<String>();
        p = MappingProposalService.validate(ClaudeService.parseObject('{"feedType": "Trade Activity", "columnMap": {"Representative": "advisorName", "Rep No.": "repCode", "Organisation": "firmName", "Security Name": "fundName", "Settle Date": "tradeDate", "Side": "transactionType", "Value": "amount"}, "dateFormat": "YYYY-MM-DD", "decimalSeparator": "Period", "directionConvention": "Type Column", "aumIndicatorValues": null, "confidence": null, "explanation": ""}'), headers, problems);
        Assert.areEqual(new List<String>{ 'confidence must be High, Medium or Low.', 'explanation is required.' }, sorted(problems), 'missing confidence and explanation: problems');
        Assert.isNull(p, 'missing confidence and explanation: no proposal');
    }
}
