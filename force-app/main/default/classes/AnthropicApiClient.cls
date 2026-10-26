/**
 * Standard tier: sends the prompt to the Anthropic Messages API with the firm's own API key.
 *
 * The key lives in the Anthropic_API external credential and the platform adds it as the x-api-key header, so it
 * never appears in code, settings or logs. Calls only work for users granted the Trade Import Anthropic API
 * permission set; without the credential or the permission the callout fails and the request is logged as
 * Failed. Requests do not pass through the Einstein Trust Layer: firms that need it use the Models API, which
 * is the default provider.
 */
public with sharing class AnthropicApiClient implements ClaudeClient {
    @TestVisible
    private static final String ENDPOINT = 'callout:Anthropic_API/v1/messages';
    @TestVisible
    private static final String API_VERSION = '2023-06-01';
    // Room for a full suggestion answer; a cut-off answer is reported rather than half-parsed.
    @TestVisible
    private static final Integer MAX_TOKENS = 8000;
    // Apex allows 120 seconds of callouts per transaction; the suggestion job stops starting new requests at 60.
    private static final Integer TIMEOUT_MS = 60000;
    private static final Integer MAX_ERROR_TEXT = 1000;

    public ClaudeService.Completion complete(String modelName, String prompt) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT);
        req.setMethod('POST');
        req.setTimeout(TIMEOUT_MS);
        req.setHeader('content-type', 'application/json');
        req.setHeader('anthropic-version', API_VERSION);
        req.setBody(System.JSON.serialize(body(modelName, prompt)));
        HttpResponse res = new Http().send(req);
        ClaudeService.Completion c = new ClaudeService.Completion(textOf(res.getStatusCode(), res.getBody()));
        return ClaudeService.withUsage(c, parse(res.getBody()));
    }

    /**
     * The Messages API request. When the prompt has a cache break, the part before it (instructions and reference
     * data, identical for every request in a run) is sent as a cached system block, so later requests in the
     * next few minutes pay a fraction of the input price for it; the items follow as the user message.
     */
    @TestVisible
    private static Map<String, Object> body(String modelName, String prompt) {
        Map<String, Object> b = new Map<String, Object>{ 'model' => modelName, 'max_tokens' => MAX_TOKENS };
        String user = prompt;
        Integer cut = prompt == null ? -1 : prompt.indexOf(ClaudeService.CACHE_BREAK);
        if (cut > 0) {
            b.put(
                'system',
                new List<Object>{
                    new Map<String, Object>{
                        'type' => 'text',
                        'text' => prompt.substring(0, cut),
                        'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' }
                    }
                }
            );
            user = prompt.substring(cut + ClaudeService.CACHE_BREAK.length());
        }
        b.put('messages', new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => ClaudeService.plain(user) } });
        return b;
    }

    /** The answer's text blocks joined, or an exception that says why there is no usable answer. */
    @TestVisible
    private static String textOf(Integer status, String body) {
        Map<String, Object> root = parse(body);
        if (status != 200) {
            throw new ClaudeService.ClaudeException('Anthropic API error ' + status + ': ' + errorText(root, body));
        }
        if (root == null) {
            throw new ClaudeService.ClaudeException('The Anthropic API returned a response that is not JSON.');
        }
        Object stop = root.get('stop_reason');
        if ('max_tokens'.equals(stop)) {
            throw new ClaudeService.ClaudeException(
                'The answer was cut off at the ' + MAX_TOKENS + '-token limit. Lower Max Items Per Request in the Trade AI Setting.'
            );
        }
        if ('refusal'.equals(stop)) {
            throw new ClaudeService.ClaudeException('Claude declined to answer this request.');
        }
        String text = '';
        Object content = root.get('content');
        if (content instanceof List<Object>) {
            for (Object blockObj : (List<Object>) content) {
                if (!(blockObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> block = (Map<String, Object>) blockObj;
                Object blockText = block.get('text');
                if ('text'.equals(block.get('type')) && blockText instanceof String) {
                    text += (String) blockText;
                }
            }
        }
        return text;
    }

    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            Object parsed = System.JSON.deserializeUntyped(body);
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        } catch (System.JSONException e) {
            return null;
        }
    }

    /** Anthropic errors look like {"type": "error", "error": {"type": "...", "message": "..."}}. */
    private static String errorText(Map<String, Object> root, String body) {
        Object err = root == null ? null : root.get('error');
        if (err instanceof Map<String, Object>) {
            Map<String, Object> e = (Map<String, Object>) err;
            return (String.valueOf(e.get('type')) + ': ' + String.valueOf(e.get('message'))).abbreviate(MAX_ERROR_TEXT);
        }
        return String.isBlank(body) ? '(no response body)' : body.trim().abbreviate(MAX_ERROR_TEXT);
    }
}
