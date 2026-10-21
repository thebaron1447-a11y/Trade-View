/**
 * Proposes a mapping profile for a batch stuck in Mapping Review because no Active profile matches its layout.
 * Queued by ImportBatchProcessor. One Claude call; all DML happens after it.
 */
public with sharing class MappingProposalJob implements Queueable, Database.AllowsCallouts {
    private final Id batchId;

    public MappingProposalJob(Id batchId) {
        this.batchId = batchId;
    }

    public void execute(QueueableContext context) {
        run(batchId);
    }

    /** Returns the Draft profile created, or null if nothing was proposed. */
    public static Mapping_Profile__c run(Id batchId) {
        if (!AiSettings.get().enabled) {
            return null;
        }
        List<Import_Batch__c> batches = [
            SELECT Id, Status__c, Source_Firm__c, Header_Fingerprint__c, Error_Message__c
            FROM Import_Batch__c
            WHERE Id = :batchId
            WITH USER_MODE
            LIMIT 1
        ];
        if (batches.isEmpty() || batches[0].Status__c != ImportBatchProcessor.STATUS_MAPPING_REVIEW) {
            return null;
        }
        Import_Batch__c batch = batches[0];
        // One proposal per layout: a re-sent file does not trigger a second request.
        if (
            String.isNotBlank(batch.Header_Fingerprint__c) &&
            [SELECT COUNT() FROM Mapping_Profile__c WHERE Header_Fingerprint__c = :batch.Header_Fingerprint__c AND Status__c = 'Draft' WITH USER_MODE] > 0
        ) {
            return null;
        }

        List<List<String>> rows;
        try {
            String text = ImportBatchProcessor.loadFile(batch.Id);
            rows = CsvParser.parse(text, CsvParser.detectDelimiter(text));
        } catch (Exception e) {
            return null; // the batch already explains why the file cannot be read
        }
        if (rows.size() < 2) {
            return null;
        }
        List<String> headers = rows[0];
        List<List<String>> sample = new List<List<String>>();
        for (Integer i = 1; i < rows.size() && sample.size() < MappingProposalService.SAMPLE_ROWS; i++) {
            sample.add(rows[i]);
        }

        String prompt = MappingProposalService.buildPrompt(batch.Source_Firm__c, headers, sample);
        ClaudeService.Result result = ClaudeService.call(MappingProposalService.PURPOSE, prompt, batch.Id, 1);
        MappingProposalService.Proposal proposal;
        if (result.ok) {
            List<String> problems = new List<String>();
            try {
                proposal = MappingProposalService.validate(ClaudeService.parseObject(result.text), headers, problems);
            } catch (ClaudeService.ClaudeException e) {
                problems.add(e.getMessage());
            }
            if (proposal == null) {
                result.reject(problems);
            }
        }

        // The callout is done; now write.
        insert as user result.log;
        if (proposal == null) {
            return null;
        }
        Mapping_Profile__c draft = MappingProposalService.toDraft(proposal, batch, headers);
        insert as user draft;
        String note = 'Claude proposed a mapping: ' + draft.Name + ' (Draft). Review its AI Rationale and set it to Active to process this file.';
        update as user new Import_Batch__c(
            Id = batch.Id,
            Error_Message__c = ((String.isBlank(batch.Error_Message__c) ? '' : batch.Error_Message__c + '\n\n') + note).abbreviate(5000)
        );
        return draft;
    }
}
