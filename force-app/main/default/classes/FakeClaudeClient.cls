/** Test double for Claude: records every prompt and returns scripted replies (a String, or an Exception to throw). */
@IsTest
public class FakeClaudeClient implements ClaudeClient {
    public List<String> prompts = new List<String>();
    public List<String> models = new List<String>();
    /** Replies are used in order; the last one repeats. */
    public List<Object> replies = new List<Object>();

    public String complete(String modelName, String prompt) {
        models.add(modelName);
        prompts.add(prompt);
        Object next = replies.isEmpty() ? null : (replies.size() > 1 ? replies.remove(0) : replies[0]);
        if (next instanceof Exception) {
            throw (Exception) next;
        }
        return (String) next;
    }

    /** Turns Claude on with test settings and routes every call to a new fake. */
    public static FakeClaudeClient install(List<Object> replies) {
        AiSettings settings = new AiSettings();
        settings.enabled = true;
        settings.modelName = 'test-model';
        settings.maxItemsPerRequest = 10;
        settings.requireTwoPersonRuleApproval = true;
        AiSettings.current = settings;
        FakeClaudeClient fake = new FakeClaudeClient();
        fake.replies.addAll(replies);
        ClaudeService.client = fake;
        return fake;
    }
}
