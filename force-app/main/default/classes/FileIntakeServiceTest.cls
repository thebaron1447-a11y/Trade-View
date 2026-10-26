@IsTest
private class FileIntakeServiceTest {
    private static String refusal(String firm, String name, Blob file, String hash) {
        try {
            FileIntakeService.receive(firm, name, file, hash);
        } catch (FileIntakeService.IntakeException e) {
            return e.getMessage();
        }
        return 'accepted';
    }

    @IsTest
    static void everyBadFileIsRefusedWithAReason() {
        Blob ok = Blob.valueOf('a,b\n1,2\n');
        Assert.isTrue(refusal('Barder & Co', 'a.csv', ok, null).startsWith('Source firm codes may contain only'), 'firm code');
        Assert.isTrue(refusal(null, 'a.csv', ok, null).startsWith('Source firm codes may contain only'), 'no firm code');
        Assert.areEqual('A file name is required.', refusal('BARDER', null, ok, null), 'no name');
        Assert.areEqual('The file name must be 255 characters or fewer.', refusal('BARDER', 'x'.repeat(256), ok, null), 'long name');
        Assert.areEqual('The file is empty.', refusal('BARDER', 'a.csv', null, null), 'no file');
        Assert.areEqual('The file is empty.', refusal('BARDER', 'a.csv', Blob.valueOf(''), null), 'empty file');
        Assert.areEqual(
            'The file is larger than 1024 KB. Ask the sender to split it.',
            refusal('BARDER', 'a.csv', Blob.valueOf('x'.repeat(FileIntakeService.MAX_FILE_BYTES + 1)), null),
            'too large'
        );
        Assert.isTrue(refusal('BARDER', 'a.csv', ok, 'abc').startsWith('fileHash does not match'), 'corrupted in transit');
        Assert.areEqual(0, [SELECT COUNT() FROM Import_Batch__c], 'nothing created');
    }

    @IsTest
    static void aGoodFileIsReceivedOnceWhateverItsName() {
        Blob file = Blob.valueOf('Representative,Rep No.\nRyan Chen,1001\n');
        String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', file));

        FileIntakeService.Receipt first = FileIntakeService.receive(' kestrel ', ' kestrel.csv ', file, hash.toUpperCase());
        FileIntakeService.Receipt again = FileIntakeService.receive('KESTREL', 'kestrel resent.csv', file, null);

        Assert.isFalse(first.duplicate, 'new');
        Assert.areEqual('File received and queued for processing.', first.message, 'message');
        Assert.isTrue(again.duplicate, 'same contents');
        Assert.areEqual('This file was already received.', again.message, 'duplicate message');
        Assert.areEqual(first.batchId, again.batchId, 'same batch');
        Import_Batch__c b = [SELECT Source_Firm__c, Source_File_Name__c, File_Hash__c, Status__c FROM Import_Batch__c];
        Assert.areEqual('KESTREL', b.Source_Firm__c, 'code trimmed and upper-cased');
        Assert.areEqual('kestrel.csv', b.Source_File_Name__c, 'name trimmed');
        Assert.areEqual(hash, b.File_Hash__c, 'hash of the contents');
        Assert.areEqual('Received', b.Status__c, 'waiting for processing');
    }
}
