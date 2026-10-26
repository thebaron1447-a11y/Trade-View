/**
 * Sends a prompt to a model and returns its text with the token counts the model reported. Production uses the
 * Models API or the Anthropic API (per the Trade AI Setting); tests substitute a fake.
 * A prompt may contain ClaudeService.CACHE_BREAK: everything before it is the same for every request in a run
 * (instructions and reference data), so a client that supports prompt caching may cache it.
 */
public interface ClaudeClient {
    ClaudeService.Completion complete(String modelName, String prompt);
}
