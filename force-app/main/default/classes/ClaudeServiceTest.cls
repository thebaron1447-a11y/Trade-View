@IsTest
private class ClaudeServiceTest {
    @IsTest
    static void successfulCallIsLogged() {
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ '{"ok": true}' });
        ClaudeService.Result r = ClaudeService.call('Row Suggestions', 'Say ok.', null, 3);
        Assert.isTrue(r.ok, 'ok');
        Assert.areEqual('{"ok": true}', r.text, 'text');
        Assert.areEqual('Success', r.log.Status__c, 'status');
        Assert.areEqual('Say ok.', r.log.Prompt__c, 'prompt kept');
        Assert.areEqual('{"ok": true}', r.log.Response__c, 'response kept');
        Assert.areEqual('test-model', r.log.Model_Name__c, 'model');
        Assert.areEqual('Models API', r.log.Provider__c, 'provider recorded');
        Assert.areEqual(1, r.log.Input_Tokens__c.intValue(), 'input tokens logged (the fake counts four characters a token)');
        Assert.areEqual(3, r.log.Output_Tokens__c.intValue(), 'output tokens logged');
        Assert.areEqual(3, r.log.Item_Count__c.intValue(), 'item count');
        Assert.isTrue(r.log.Duration_Ms__c >= 0, 'duration');
        Assert.areEqual('Say ok.', fake.prompts[0], 'prompt sent');
        Assert.isNull(r.log.Id, 'the caller inserts the log after its callouts');
    }

    @IsTest
    static void emptyOrFailedCallsAreRecordedNotThrown() {
        FakeClaudeClient.install(new List<Object>{ '   ', new ClaudeService.ClaudeException('Service unavailable') });
        ClaudeService.Result empty = ClaudeService.call('Row Suggestions', 'p', null, 1);
        Assert.isFalse(empty.ok, 'empty is a failure');
        Assert.areEqual('Failed', empty.log.Status__c, 'empty status');
        Assert.isTrue(empty.log.Error_Message__c.contains('empty response'), 'error: ' + empty.log.Error_Message__c);
        ClaudeService.Result failed = ClaudeService.call('Row Suggestions', 'p', null, 1);
        Assert.areEqual('Failed', failed.log.Status__c, 'failed status');
        Assert.isTrue(failed.log.Error_Message__c.contains('Service unavailable'), 'error: ' + failed.log.Error_Message__c);
    }

    @IsTest
    static void rejectAndNoteRecordProblems() {
        FakeClaudeClient.install(new List<Object>{ 'x' });
        ClaudeService.Result r = ClaudeService.call('Mapping Proposal', 'p', null, 1);
        r.note(new List<String>());
        Assert.isNull(r.log.Error_Message__c, 'nothing to note');
        r.note(new List<String>{ 'Item R1: bad' });
        Assert.isTrue(r.log.Error_Message__c.startsWith('Some items were discarded'), 'error: ' + r.log.Error_Message__c);
        r.reject(new List<String>{ 'not JSON' });
        Assert.isFalse(r.ok, 'rejected');
        Assert.areEqual('Invalid Response', r.log.Status__c, 'invalid');
        Assert.areEqual('not JSON', r.log.Error_Message__c, 'reason');
    }

    @IsTest
    static void providerSettingPicksTheClient() {
        ClaudeService.client = null;
        AiSettings s = new AiSettings();
        Assert.isTrue(ClaudeService.clientFor(s) instanceof ClaudeService.ModelsApiClient, 'Models API by default');
        s.provider = AiSettings.PROVIDER_ANTHROPIC;
        Assert.isTrue(ClaudeService.clientFor(s) instanceof AnthropicApiClient, 'Anthropic API when chosen');
    }

    @IsTest
    static void anthropicProviderCallsTheApiAndRecordsTheRoute() {
        AiSettings s = new AiSettings();
        s.enabled = true;
        s.provider = AiSettings.PROVIDER_ANTHROPIC;
        s.anthropicModel = 'claude-test';
        AiSettings.current = s;
        ClaudeService.client = null;
        AnthropicApiClientTest.Mock mock = new AnthropicApiClientTest.Mock(200, '{"content": [{"type": "text", "text": "{\\"ok\\": true}"}], "stop_reason": "end_turn"}');
        Test.setMock(HttpCalloutMock.class, mock);

        ClaudeService.Result r = ClaudeService.call('Row Suggestions', 'Say ok.', null, 1);

        Assert.isTrue(r.ok, 'ok: ' + r.log.Error_Message__c);
        Assert.areEqual('{"ok": true}', r.text, 'text from the content block');
        Assert.areEqual('Anthropic API', r.log.Provider__c, 'route recorded on the log');
        Assert.areEqual('claude-test', r.log.Model_Name__c, 'Anthropic model recorded');
        Assert.areEqual('claude-test', ((Map<String, Object>) System.JSON.deserializeUntyped(mock.received.getBody())).get('model'), 'Anthropic model sent');
    }

    @IsTest
    static void missingCredentialIsRecordedAsFailed() {
        AiSettings s = new AiSettings();
        s.enabled = true;
        s.provider = AiSettings.PROVIDER_ANTHROPIC;
        AiSettings.current = s;
        ClaudeService.client = null;
        AnthropicApiClientTest.Mock mock = new AnthropicApiClientTest.Mock(200, '{}');
        mock.failure = new CalloutException('We could not access the credential');
        Test.setMock(HttpCalloutMock.class, mock);

        ClaudeService.Result r = ClaudeService.call('Row Suggestions', 'p', null, 1);

        Assert.isFalse(r.ok, 'no answer without the credential');
        Assert.areEqual('Failed', r.log.Status__c, 'logged as Failed, never thrown');
        Assert.isTrue(r.log.Error_Message__c.contains('CalloutException'), 'error: ' + r.log.Error_Message__c);
    }

    @IsTest
    static void tokenCountsAreFoundInEitherProvidersResponse() {
        // Models API: parameters.usage, OpenAI style.
        ClaudeService.Completion models = ClaudeService.withUsage(
            new ClaudeService.Completion('x'),
            System.JSON.deserializeUntyped('{"generation": {"generatedText": "x", "parameters": {"finish_reason": "stop"}}, "parameters": {"usage": {"completion_tokens": 607, "prompt_tokens": 39, "total_tokens": 646}}}')
        );
        Assert.areEqual(39, models.inputTokens, 'prompt tokens');
        Assert.areEqual(607, models.outputTokens, 'completion tokens');
        Assert.isNull(models.cachedInputTokens, 'no caching on the Models API');
        // Anthropic: usage at the top, with cache counts.
        ClaudeService.Completion anthropic = ClaudeService.withUsage(
            new ClaudeService.Completion('x'),
            System.JSON.deserializeUntyped('{"usage": {"input_tokens": 10, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 0, "output_tokens": 200}}')
        );
        Assert.areEqual(3010, anthropic.inputTokens, 'written to cache counts as input');
        Assert.areEqual(0, anthropic.cachedInputTokens, 'nothing read from cache yet');
        // No usage at all.
        ClaudeService.Completion none = ClaudeService.withUsage(new ClaudeService.Completion('x'), System.JSON.deserializeUntyped('{"a": [1, {"b": 2}]}'));
        Assert.isNull(none.inputTokens, 'unknown stays blank');
        Assert.isNull(ClaudeService.withUsage(new ClaudeService.Completion('x'), null).outputTokens, 'no response, no counts');
    }

    @IsTest
    static void theCacheMarkerNeverReachesTheLog() {
        FakeClaudeClient fake = FakeClaudeClient.install(new List<Object>{ '{"ok": true}' });
        ClaudeService.Result r = ClaudeService.call('Row Suggestions', 'RULES' + ClaudeService.CACHE_BREAK + 'ITEMS', null, 1);
        Assert.areEqual('RULES\n\nITEMS', r.log.Prompt__c, 'logged as plain text');
        Assert.isTrue(fake.prompts[0].contains(ClaudeService.CACHE_BREAK), 'the client still sees where the cache ends');
    }

    @IsTest
    static void jsonIsFoundInsideProse() {
        Map<String, Object> parsed = ClaudeService.parseObject('Sure! ```json\n{"a": {"b": 1}}\n``` Hope that helps.');
        Assert.areEqual(1, ((Map<String, Object>) parsed.get('a')).get('b'), 'nested value');
    }
}
