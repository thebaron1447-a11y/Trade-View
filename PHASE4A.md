# Phase 4a: Standard tier (Claude through the Anthropic API)

The app now runs at two price points, chosen by one setting:

| | Enterprise tier (default) | Standard tier |
|---|---|---|
| Claude reached through | Models API, Einstein Trust Layer | Anthropic Messages API, the firm's own key |
| Needs | Einstein generative AI | An Anthropic API key, stored in Salesforce as a credential |
| Everything else | Same prompt, validation, key clean-up, AI Request Log, review and roster approval | Identical |

Every AI Request Log now records its **Provider**, so you can show which route each prompt took.

What was added:
- `AnthropicApiClient` (with `AnthropicApiClientTest`); `AiSettings` and `ClaudeService` choose the client from the setting.
- Trade AI Setting fields **Provider** (default Models API) and **Anthropic Model** (claude-sonnet-5-5).
- AI Request Log field **Provider** (on the layout and list view).
- External credential and named credential **Anthropic_API**, and the permission set **Trade Import Anthropic API**.
  An Enterprise org can leave all three out: no Apex depends on them at compile time.

## 1. Validate (20 test classes, expect 118 tests)

```powershell
cd C:\dev\trade-import-demo
sf project deploy start --source-dir C:\dev\trade-import-demo\force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests AiSettingsTest --tests AnthropicApiClientTest --tests ClaudeServiceTest --tests ClaudeSuggestionTest --tests ClaudeValidationVectorTest --tests CsvParserTest --tests DemoScenarioTest --tests ImportBatchProcessorTest --tests MappingProposalTest --tests MappingServiceTest --tests MatchingRuleTest --tests NameMatcherTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests ReviewDecisionTest --tests RosterApprovalTest --tests TradeIngestResourceTest --tests TradeMatcherTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only on `Status: Succeeded`. If anything fails, send the full output. The external and named credential
files are the parts most likely to need a tweak, because only the org can check them.

## 2. Deploy

The same command without `--dry-run --verbose`. Provider stays **Models API**, so the demo behaves exactly as before.

Note: every deploy resets the Default setting record from the project, so Provider goes back to Models API after a
deploy. That is deliberate: the compliant route is what the code ships with.

## 3. Set up the Standard tier (once)

1. Create an API key at console.anthropic.com (Settings > API Keys). Copy it; it is shown once.
2. In Salesforce: Setup > **Named Credentials** > **External Credentials** tab > **Anthropic API**.
3. In **Principals**, on the row **Anthropic**, choose **Edit** from the row menu.
4. Under **Authentication Parameters**, click **Add**: Name `ApiKey`, Value: your key. Save.
   The key is stored encrypted by Salesforce. It never goes in the repository, a file or a chat.
5. Give yourself access (the push job runs as you, so its background jobs call as you):

   ```powershell
   sf org assign permset --name Trade_Import_Anthropic_API --target-org tradeDemo
   ```

## 4. Switch to the Standard tier and run the demo

1. Setup > **Custom Metadata Types** > Trade AI Setting > **Manage Records** > **Default** > Edit.
   Set **Provider** to **Anthropic API**. Save.
2. Run the demo as usual: `reset-imports.apex`, push the roster, wait 30 seconds, push the trade files, wait two minutes.
3. Check the logs:

   ```powershell
   sf data query --query "SELECT Name, Purpose__c, Provider__c, Model_Name__c, Status__c, Duration_Ms__c, Error_Message__c FROM AI_Request_Log__c ORDER BY Name" --target-org tradeDemo
   ```

   Every log should show Provider **Anthropic API**, model **claude-sonnet-5-5**, Status **Success**. The suggestions
   on rows and follow-ups should read like the Models API ones.
4. Switch Provider back to **Models API** when you are done.

If a log says Failed, its Error Message says why:

| Error Message contains | Cause |
|---|---|
| `authentication_error` | The ApiKey value is wrong or was revoked |
| `CalloutException` mentioning the credential | The permission set is not assigned, or the ApiKey parameter is missing |
| `not_found_error` with the model | The Anthropic Model setting names a model your key cannot use |
| `cut off at the 8000-token limit` | Lower Max Items Per Request |

## Optional: show the control working

Before step 3.5 (permission set not yet assigned), switch Provider to Anthropic API and run the demo: every request is
logged **Failed** with a credential error, and nothing is sent. That is the second lock: changing the setting alone
cannot send data to Anthropic.
