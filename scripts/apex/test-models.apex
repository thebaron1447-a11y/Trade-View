// Checks which Claude models this org can call through the Models API.
// Run: sf apex run --file scripts/apex/test-models.apex --target-org tradeDemo
// Each call uses a few Einstein Requests; the prompt is kept tiny on purpose.
List<String> models = new List<String>{
    'sfdc_ai__DefaultBedrockAnthropicClaude5Sonnet',
    'sfdc_ai__DefaultBedrockAnthropicClaude46Sonnet',
    'sfdc_ai__DefaultBedrockAnthropicClaude45Haiku'
};
aiplatform.ModelsAPI api = new aiplatform.ModelsAPI();
for (String model : models) {
    aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
    req.modelName = model;
    aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
    body.prompt = 'Reply with exactly: OK';
    req.body = body;
    try {
        String text = api.createGenerations(req).Code200.generation.generatedText;
        System.debug(LoggingLevel.INFO, 'MODEL TEST | ' + model + ' | AVAILABLE | ' + text);
    } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
        System.debug(LoggingLevel.INFO, 'MODEL TEST | ' + model + ' | FAILED | HTTP ' + e.responseCode + ' | ' + e.getMessage());
    } catch (Exception e) {
        System.debug(LoggingLevel.INFO, 'MODEL TEST | ' + model + ' | FAILED | ' + e.getTypeName() + ' | ' + e.getMessage());
    }
}
