# Phase 2: Ingestion

Extract this zip into `C:\dev\trade-import-demo`, letting it overwrite. You should end up with
`force-app`, `scripts`, `pushjob` and `datalake` at the project root. Run everything from that folder.

## 1. Validate (compiles everything and runs this project's tests, then rolls back)

```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run --verbose --test-level RunSpecifiedTests --tests CsvParserTest --tests ImportBatchProcessorTest --tests MappingServiceTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests TradeIngestResourceTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
```

Continue only if this reports `Status: Succeeded` with all tests passing. If anything fails, send the full output.

Why RunSpecifiedTests: the org already contains Apex that is not part of this project (BookOfBusinessController
and several Agentforce action classes) with 0% coverage, which pulls the org-wide average below 75%. With
RunSpecifiedTests, Salesforce instead requires each class in this deployment to reach 75% from the listed tests.

## 2. Deploy and seed the mapping profiles

```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --test-level RunSpecifiedTests --tests CsvParserTest --tests ImportBatchProcessorTest --tests MappingServiceTest --tests NameNormalizerTest --tests ProductDeleteGuardTest --tests TradeIngestResourceTest --tests TradeRowNormalizerTest --tests TradeRowNormalizerVectorTest
sf apex run --file scripts/apex/seed-mapping-profiles.apex --target-org tradeDemo
```

The seed script creates Active profiles for BARDER, NORTHGATE and LUMIERE. KESTREL is left without one on purpose.
Your Trade_Import_Admin assignment picks up the new objects automatically.

## 3. Set up the push job (once)

```powershell
cd pushjob
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m unittest test_push_job.py
```

## 4. Push the data lake

```powershell
python push_job.py --lake ..\datalake --once --auth sfcli --target-org tradeDemo
```

Expected: four `SENT` lines. Files move from `datalake\inbox` to `datalake\processed`.
Processing runs in the background; wait about 30 seconds, then check:

```powershell
sf data query --query "SELECT Name, Source_Firm__c, Status__c, Row_Count__c, Error_Row_Count__c, Error_Message__c FROM Import_Batch__c ORDER BY Name" --target-org tradeDemo
```

| Firm | Status | Rows | Error rows | Why |
|---|---|---|---|---|
| BARDER | Staged | 7 | 1 | One row has no amount |
| KESTREL | Mapping Review | 2 | 0 | No profile for this layout (planted) |
| LUMIERE | Staged | 4 | 0 | French headers, semicolons, decimal commas all handled |
| NORTHGATE | Staged | 7 | 2 | 31/09/2026 is not a date; SWITCH is not a buy or sell |

To see the normalized rows:

```powershell
sf data query --query "SELECT Import_Batch__r.Source_Firm__c, Row_Number__c, Source_Rep_Code__c, Source_Advisor_Name__c, Source_Firm_Name__c, Source_Fund_Name__c, Trade_Date__c, Transaction_Type__c, Amount__c, Validation_Errors__c FROM Import_Staging_Row__c ORDER BY Import_Batch__r.Name, Row_Number__c" --target-org tradeDemo
```

## 5. Prove duplicate protection

Copy any file from `datalake\processed\<FIRM>\` back into `datalake\inbox\<FIRM>\` and push again.
Expected: `DUPLICATE ... -> batch <same Id>` and no new batch.

## 6. Watch mode (for the demo)

```powershell
python push_job.py --lake ..\datalake --watch --interval 10 --auth sfcli --target-org tradeDemo
```

Drop a file into an inbox folder and it is sent within 10 seconds.

## 7. Optional: JWT authentication (how a real scheduled job logs in)

`--auth sfcli` borrows your CLI login, which is fine for a demo. A production job uses its own
credentials. See `pushjob\JWT_SETUP.md`.

## Limits (by design)

- Files up to 1 MB and 5,000 data rows (about one week of volume); larger files are rejected with a clear message.
- Files must be UTF-8 (a byte order mark is fine).
- Raw files are kept on the batch as an attachment; every row is kept raw as JSON.
