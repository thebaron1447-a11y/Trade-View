/**
 * The only place that calls Claude. Every call produces an AI_Request_Log__c record with the exact prompt,
 * the raw response, the model and the duration. The caller inserts the log after all of its callouts,
 * because Apex does not allow a callout after DML in the same transaction.
 *
 * Two providers, chosen by the Trade AI Setting: the Models API (default, Enterprise tier), so requests
 * pass through the Einstein Trust Layer, or the Anthropic Messages API with the firm's own key (Standard
 * tier, AnthropicApiClient). Everything else (prompt, validation, logging) is identical. Each log records
 * its provider. Responses are never trusted: callers parse them here and validate them against exactly
 * what they asked for before anything is written.
 */
public with sharing class ClaudeService {
    public class ClaudeException extends Exception {
    }

    /** Marks the end of the part of a prompt that is identical across a run, so it can be cached. */
    public static final String CACHE_BREAK = '\n\n[[[CACHE-BREAK]]]\n';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_INVALID = 'Invalid Response';
    public static final String STATUS_FAILED = 'Failed';
    private static final Integer LONG_TEXT = 131072;
    private static final Integer ERROR_TEXT = 5000;

    /** Set by tests to route every call to a fake; null in production, where the provider setting decides. */
    @TestVisible
    private static ClaudeClient client;

    @TestVisible
    private static ClaudeClient clientFor(AiSettings settings) {
        if (client != null) {
            return client;
        }
        return settings.provider == AiSettings.PROVIDER_ANTHROPIC ? (ClaudeClient) new AnthropicApiClient() : (ClaudeClient) new ModelsApiClient();
    }

    /** A model's answer and the token counts it reported (null when the provider does not report them). */
    public class Completion {
        public String text;
        public Integer inputTokens;
        public Integer outputTokens;
        public Integer cachedInputTokens;

        public Completion(String text) {
            this.text = text;
        }
    }

    /** The outcome of one call and its unsaved log record. */
    public class Result {
        public Boolean ok = false;
        public String text;
        public AI_Request_Log__c log;

        /** Marks a response that arrived but failed validation; nothing from it may be applied. */
        public void reject(List<String> problems) {
            ok = false;
            log.Status__c = STATUS_INVALID;
            log.Error_Message__c = String.join(problems, '\n').abbreviate(ERROR_TEXT);
        }

        /** Records item-level problems on an otherwise usable response. */
        public void note(List<String> problems) {
            if (!problems.isEmpty()) {
                log.Error_Message__c = ('Some items were discarded:\n' + String.join(problems, '\n')).abbreviate(ERROR_TEXT);
            }
        }
    }

    public static Result call(String purpose, String prompt, Id batchId, Integer itemCount) {
        AiSettings settings = AiSettings.get();
        Result r = new Result();
        r.log = new AI_Request_Log__c(
            Purpose__c = purpose,
            Provider__c = settings.provider,
            Model_Name__c = settings.activeModel(),
            Prompt__c = prompt == null ? null : plain(prompt).abbreviate(LONG_TEXT),
            Import_Batch__c = batchId,
            Item_Count__c = itemCount
        );
        Long started = System.currentTimeMillis();
        try {
            Completion c = clientFor(settings).complete(settings.activeModel(), prompt);
            r.text = c?.text;
            r.log.Input_Tokens__c = c?.inputTokens;
            r.log.Output_Tokens__c = c?.outputTokens;
            r.log.Cached_Input_Tokens__c = c?.cachedInputTokens;
            if (String.isBlank(r.text)) {
                throw new ClaudeException('The model returned an empty response.');
            }
            r.ok = true;
            r.log.Status__c = STATUS_SUCCESS;
            r.log.Response__c = r.text.abbreviate(LONG_TEXT);
        } catch (Exception e) {
            // Any failure (callout, permission, timeout, empty answer) is recorded, never thrown:
            // the items are marked Failed and the rest of the job carries on.
            r.ok = false;
            r.log.Status__c = STATUS_FAILED;
            r.log.Error_Message__c = (e.getTypeName() + ': ' + e.getMessage()).abbreviate(ERROR_TEXT);
        }
        r.log.Duration_Ms__c = System.currentTimeMillis() - started;
        return r;
    }

    /** The prompt without the cache marker: what a provider without caching is sent, and what the log records. */
    public static String plain(String prompt) {
        return prompt == null ? null : prompt.replace(CACHE_BREAK, '\n\n');
    }

    /**
     * Fills the token counts from a provider response, wherever they appear in it. Recognises OpenAI-style
     * (prompt_tokens, completion_tokens) and Anthropic-style (input_tokens, output_tokens, plus cache_read_input_tokens
     * and cache_creation_input_tokens) usage objects. Input tokens are the whole prompt, cached or not.
     */
    public static Completion withUsage(Completion c, Object response) {
        Map<String, Object> usage = findUsage(response, 0);
        if (usage == null) {
            return c;
        }
        Integer cacheRead = toInteger(usage.get('cache_read_input_tokens'));
        Integer cacheWrite = toInteger(usage.get('cache_creation_input_tokens'));
        Integer input = toInteger(usage.containsKey('prompt_tokens') ? usage.get('prompt_tokens') : usage.get('input_tokens'));
        if (input != null && usage.containsKey('input_tokens')) {
            input += (cacheRead == null ? 0 : cacheRead) + (cacheWrite == null ? 0 : cacheWrite);
        }
        c.inputTokens = input;
        c.outputTokens = toInteger(usage.containsKey('completion_tokens') ? usage.get('completion_tokens') : usage.get('output_tokens'));
        c.cachedInputTokens = cacheRead;
        return c;
    }

    private static Map<String, Object> findUsage(Object node, Integer depth) {
        if (depth > 6) {
            return null;
        }
        if (node instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) node;
            if (m.containsKey('prompt_tokens') || m.containsKey('input_tokens')) {
                return m;
            }
            for (Object child : m.values()) {
                Map<String, Object> found = findUsage(child, depth + 1);
                if (found != null) {
                    return found;
                }
            }
        } else if (node instanceof List<Object>) {
            for (Object child : (List<Object>) node) {
                Map<String, Object> found = findUsage(child, depth + 1);
                if (found != null) {
                    return found;
                }
            }
        }
        return null;
    }

    private static Integer toInteger(Object v) {
        if (v instanceof Integer) {
            return (Integer) v;
        }
        if (v instanceof Long) {
            return ((Long) v).intValue();
        }
        if (v instanceof Decimal) {
            return ((Decimal) v).intValue();
        }
        return null;
    }

    /**
     * The JSON object in a response. Claude is asked for bare JSON but may wrap it in a code fence or a
     * sentence, so the text from the first "{" to the last "}" is parsed.
     */
    public static Map<String, Object> parseObject(String text) {
        Integer start = text == null ? -1 : text.indexOf('{');
        Integer finish = text == null ? -1 : text.lastIndexOf('}');
        if (start < 0 || finish < start) {
            throw new ClaudeException('The response contains no JSON object.');
        }
        try {
            return (Map<String, Object>) System.JSON.deserializeUntyped(text.substring(start, finish + 1));
        } catch (System.JSONException e) {
            throw new ClaudeException('The response is not valid JSON: ' + e.getMessage());
        }
    }

    /** Sends the prompt through the Models API. Must run where callouts are allowed (a queueable with AllowsCallouts). */
    @TestVisible
    private with sharing class ModelsApiClient implements ClaudeClient {
        public Completion complete(String modelName, String prompt) {
            aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
            request.modelName = modelName;
            aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
            body.prompt = plain(prompt);
            request.body = body;
            aiplatform.ModelsAPI.createGenerations_Response response;
            try {
                response = new aiplatform.ModelsAPI().createGenerations(request);
            } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
                throw new ClaudeException('Models API error ' + e.responseCode + ': ' + e.getMessage());
            }
            Completion c = new Completion(response?.Code200?.generation?.generatedText);
            try {
                // Token counts are in the response's parameters.usage; read them without depending on its Apex shape.
                withUsage(c, System.JSON.deserializeUntyped(System.JSON.serialize(response.Code200)));
            } catch (Exception e) {
                // Counting tokens must never cost the answer.
                c.inputTokens = null;
            }
            return c;
        }
    }
}
