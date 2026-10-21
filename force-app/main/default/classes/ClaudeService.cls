/**
 * The only place that calls Claude. Every call produces an AI_Request_Log__c record with the exact prompt,
 * the raw response, the model and the duration. The caller inserts the log after all of its callouts,
 * because Apex does not allow a callout after DML in the same transaction.
 *
 * Claude is reached through the Models API (aiplatform namespace), so requests pass through the
 * Einstein Trust Layer. Responses are never trusted: callers parse them here and validate them against
 * exactly what they asked for before anything is written.
 */
public with sharing class ClaudeService {
    public class ClaudeException extends Exception {
    }

    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_INVALID = 'Invalid Response';
    public static final String STATUS_FAILED = 'Failed';
    private static final Integer LONG_TEXT = 131072;
    private static final Integer ERROR_TEXT = 5000;

    @TestVisible
    private static ClaudeClient client = new ModelsApiClient();

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
            Model_Name__c = settings.modelName,
            Prompt__c = prompt == null ? null : prompt.abbreviate(LONG_TEXT),
            Import_Batch__c = batchId,
            Item_Count__c = itemCount
        );
        Long started = System.currentTimeMillis();
        try {
            r.text = client.complete(settings.modelName, prompt);
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
        public String complete(String modelName, String prompt) {
            aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
            request.modelName = modelName;
            aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
            body.prompt = prompt;
            request.body = body;
            try {
                return new aiplatform.ModelsAPI().createGenerations(request)?.Code200?.generation?.generatedText;
            } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
                throw new ClaudeException('Models API error ' + e.responseCode + ': ' + e.getMessage());
            }
        }
    }
}
