@IsTest
private class SystemWriterTest {
    private static Import_Batch__c batch() {
        Import_Batch__c b = new Import_Batch__c(Source_Firm__c = 'WRITER', File_Hash__c = 'writer-test-' + Crypto.getRandomInteger(), Status__c = 'Received');
        insert b;
        return b;
    }

    @IsTest
    static void savesFieldsTheUserCannotEdit() {
        Import_Batch__c b = batch();
        // A Standard User with none of the app's permission sets: no access to batches at all.
        User plain = TestDataFactory.userWithPermissionSets(new List<String>());

        System.runAs(plain) {
            String refused = 'no error';
            try {
                update as user new Import_Batch__c(Id = b.Id, Status__c = 'Failed');
            } catch (Exception e) {
                refused = e.getTypeName();
            }
            Assert.areNotEqual('no error', refused, 'the user cannot change the batch status by hand');
            SystemWriter.updateOne(new Import_Batch__c(Id = b.Id, Status__c = 'Failed', Error_Message__c = 'Set by the system writer.'));
        }

        Import_Batch__c saved = [SELECT Status__c, Error_Message__c FROM Import_Batch__c WHERE Id = :b.Id];
        Assert.areEqual('Failed', saved.Status__c, 'the writer saved it in system mode');
        Assert.areEqual('Set by the system writer.', saved.Error_Message__c, 'every field it was given');
    }

    @IsTest
    static void insertsReturnIdsAndEmptyListsDoNothing() {
        List<Import_Batch__c> batches = new List<Import_Batch__c>{
            new Import_Batch__c(Source_Firm__c = 'WRITER', File_Hash__c = 'writer-a', Status__c = 'Received'),
            new Import_Batch__c(Source_Firm__c = 'WRITER', File_Hash__c = 'writer-b', Status__c = 'Received')
        };
        SystemWriter.insertAll(batches);
        Assert.isNotNull(batches[0].Id, 'ids are filled in, like an insert statement');
        Assert.isNotNull(batches[1].Id, 'for every record');

        Integer before = Limits.getDmlStatements();
        SystemWriter.insertAll(new List<SObject>());
        SystemWriter.updateAll(null);
        Assert.areEqual(before, Limits.getDmlStatements(), 'nothing to save costs no DML');
    }

    @IsTest
    static void aFailedSaveThrowsAndLeavesTheWriterIdle() {
        Import_Batch__c b = batch();
        Assert.isFalse(SystemWriter.isActive(), 'idle before a save');
        String failure = 'no error';
        try {
            // All or none: one bad record fails the whole save, as with a DML statement.
            SystemWriter.updateAll(
                new List<Import_Batch__c>{ new Import_Batch__c(Id = b.Id, Status__c = 'Failed'), new Import_Batch__c(Status__c = 'Failed') }
            );
        } catch (DmlException e) {
            failure = e.getMessage();
        }
        Assert.areNotEqual('no error', failure, 'a record without an Id cannot be updated');
        Assert.isFalse(SystemWriter.isActive(), 'idle again after the failure');
        Assert.areEqual('Received', [SELECT Status__c FROM Import_Batch__c WHERE Id = :b.Id].Status__c, 'nothing was saved');
    }
}
