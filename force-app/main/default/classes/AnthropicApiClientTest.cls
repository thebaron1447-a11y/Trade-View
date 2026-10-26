@IsTest
public class AnthropicApiClientTest {
    /** Records the request and returns a scripted response, or throws a scripted failure. */
    public class Mock implements HttpCalloutMock {
        public HttpRequest received;
        public CalloutException failure;
        private Integer status;
        private String body;

        public Mock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            received = req;
            if (failure != null) {
                throw failure;
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private static String errorOf(Integer status, String body) {
        try {
            AnthropicApiClient.textOf(status, body);
        } catch (ClaudeService.ClaudeException e) {
            return e.getMessage();
        }
        return 'no exception';
    }

    @IsTest
    static void sendsAMessagesRequestAndJoinsTheTextBlocks() {
        Mock mock = new Mock(
            200,
            '{"id": "msg_1", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "Part one. "}, {"type": "thinking", "thinking": "hidden"}, {"type": "text", "text": "Part two."}], "stop_reason": "end_turn", "usage": {"input_tokens": 12, "output_tokens": 7}}'
        );
        Test.setMock(HttpCalloutMock.class, mock);

        ClaudeService.Completion c = new AnthropicApiClient().complete('claude-test', 'Hello');

        Assert.areEqual('Part one. Part two.', c.text, 'text blocks joined, other blocks ignored');
        Assert.areEqual(12, c.inputTokens, 'input tokens reported');
        Assert.areEqual(7, c.outputTokens, 'output tokens reported');
        Assert.isNull(c.cachedInputTokens, 'nothing cached');
        Assert.areEqual('callout:Anthropic_API/v1/messages', mock.received.getEndpoint(), 'through the named credential');
        Assert.areEqual('POST', mock.received.getMethod(), 'method');
        Assert.areEqual('2023-06-01', mock.received.getHeader('anthropic-version'), 'API version header');
        Assert.areEqual('application/json', mock.received.getHeader('content-type'), 'content type');
        Assert.isNull(mock.received.getHeader('x-api-key'), 'the key is added by the platform, never by code');
        Map<String, Object> body = (Map<String, Object>) System.JSON.deserializeUntyped(mock.received.getBody());
        Assert.areEqual('claude-test', body.get('model'), 'model');
        Assert.areEqual(AnthropicApiClient.MAX_TOKENS, (Integer) body.get('max_tokens'), 'max tokens');
        Map<String, Object> message = (Map<String, Object>) ((List<Object>) body.get('messages'))[0];
        Assert.areEqual('user', message.get('role'), 'role');
        Assert.areEqual('Hello', message.get('content'), 'prompt sent as the user message');
        Assert.isFalse(body.containsKey('system'), 'no cached block without a cache break');
    }

    @IsTest
    static void theRepeatedPartOfThePromptIsCached() {
        Mock mock = new Mock(
            200,
            '{"content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn", "usage": {"input_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 4000, "output_tokens": 300}}'
        );
        Test.setMock(HttpCalloutMock.class, mock);

        ClaudeService.Completion c = new AnthropicApiClient().complete('claude-test', 'INSTRUCTIONS AND REFERENCE' + ClaudeService.CACHE_BREAK + 'ITEMS: R1');

        Map<String, Object> body = (Map<String, Object>) System.JSON.deserializeUntyped(mock.received.getBody());
        Map<String, Object> cachedBlock = (Map<String, Object>) ((List<Object>) body.get('system'))[0];
        Assert.areEqual('INSTRUCTIONS AND REFERENCE', cachedBlock.get('text'), 'repeated part sent as the system block');
        Assert.areEqual('ephemeral', ((Map<String, Object>) cachedBlock.get('cache_control')).get('type'), 'marked for caching');
        Map<String, Object> message = (Map<String, Object>) ((List<Object>) body.get('messages'))[0];
        Assert.areEqual('ITEMS: R1', message.get('content'), 'items sent as the user message');
        Assert.isFalse(mock.received.getBody().contains('CACHE-BREAK'), 'the marker never leaves Salesforce');
        Assert.areEqual(4050, c.inputTokens, 'input counts cached and uncached tokens');
        Assert.areEqual(4000, c.cachedInputTokens, 'cached tokens');
        Assert.areEqual(300, c.outputTokens, 'output tokens');
    }

    @IsTest
    static void apiErrorsAreReportedWithTheirReason() {
        Assert.areEqual(
            'Anthropic API error 401: authentication_error: invalid x-api-key',
            errorOf(401, '{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}'),
            'Anthropic error body'
        );
        Assert.areEqual('Anthropic API error 529: Overloaded', errorOf(529, '  Overloaded  '), 'plain text body');
        Assert.areEqual('Anthropic API error 500: (no response body)', errorOf(500, ''), 'empty body');
        Assert.areEqual('Anthropic API error 500: (no response body)', errorOf(500, null), 'null body');
    }

    @IsTest
    static void unusableAnswersAreReportedNotHalfParsed() {
        Assert.isTrue(errorOf(200, '{"content": [{"type": "text", "text": "{\\"a\\":"}], "stop_reason": "max_tokens"}').contains('cut off'), 'cut-off answer');
        Assert.areEqual('Claude declined to answer this request.', errorOf(200, '{"content": [], "stop_reason": "refusal"}'), 'refusal');
        Assert.areEqual('The Anthropic API returned a response that is not JSON.', errorOf(200, '<html>gateway</html>'), 'not JSON');
        Assert.areEqual('The Anthropic API returned a response that is not JSON.', errorOf(200, '[1, 2]'), 'JSON but not an object');
    }

    @IsTest
    static void oddButValidShapesGiveEmptyText() {
        // Empty text is turned into a Failed request by ClaudeService ("empty response").
        Assert.areEqual('', AnthropicApiClient.textOf(200, '{"content": [], "stop_reason": "end_turn"}'), 'no blocks');
        Assert.areEqual('', AnthropicApiClient.textOf(200, '{"stop_reason": "end_turn"}'), 'no content');
        Assert.areEqual('', AnthropicApiClient.textOf(200, '{"content": ["x", {"type": "text", "text": 5}]}'), 'malformed blocks skipped');
    }
}
