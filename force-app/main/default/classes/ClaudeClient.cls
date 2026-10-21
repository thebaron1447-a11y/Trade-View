/** Sends a prompt to a model and returns its text. Production uses the Models API; tests substitute a fake. */
public interface ClaudeClient {
    String complete(String modelName, String prompt);
}
