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
    static void jsonIsFoundInsideProse() {
        Map<String, Object> parsed = ClaudeService.parseObject('Sure! ```json\n{"a": {"b": 1}}\n``` Hope that helps.');
        Assert.areEqual(1, ((Map<String, Object>) parsed.get('a')).get('b'), 'nested value');
    }
}
