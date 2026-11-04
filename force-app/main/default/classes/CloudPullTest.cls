@IsTest
private class CloudPullTest {
    private static final String HARBOUR_CSV = 'Representative,Rep No.\nRyan Chen,1001\n';

    /** A bucket in memory. */
    private class FakeStorage implements CloudStorage {
        public List<CloudPullService.CloudObject> listed = new List<CloudPullService.CloudObject>();
        public Map<String, Blob> contents = new Map<String, Blob>();
        public Set<String> unreadable = new Set<String>();
        public Boolean listFails = false;
        public List<String> reads = new List<String>();

        public void put(String key, String etag, String body) {
            CloudPullService.CloudObject o = new CloudPullService.CloudObject();
            o.key = key;
            o.etag = etag;
            o.size = body == null ? 2 * 1024 * 1024 : Blob.valueOf(body).size();
            listed.add(o);
            if (body != null) {
                contents.put(key, Blob.valueOf(body));
            }
        }

        public List<CloudPullService.CloudObject> listFiles(Cloud_Source__c source) {
            if (listFails) {
                throw new CloudPullService.CloudException('S3 refused the request (403 AccessDenied): Access Denied');
            }
            return listed;
        }

        public Blob readFile(Cloud_Source__c source, String key) {
            reads.add(key);
            if (unreadable.contains(key)) {
                throw new CloudPullService.CloudException('S3 refused the request (500)');
            }
            return contents.get(key);
        }
    }

    private static FakeStorage bucket() {
        FakeStorage fake = new FakeStorage();
        CloudPullService.storageOverride = fake;
        AiSettings.current = new AiSettings();
        return fake;
    }

    private static Cloud_Source__c source(String frequency) {
        Cloud_Source__c s = new Cloud_Source__c(
            Name = 'Dealer drop',
            Provider__c = 'Amazon S3',
            Named_Credential__c = 'Trade_View_S3',
            Folder__c = 'inbox/',
            Active__c = true,
            Pull_Frequency__c = frequency,
            Pull_Hour__c = frequency == 'Daily' ? 6 : null
        );
        insert s;
        return s;
    }

    private static Cloud_Source__c reload(Id sourceId) {
        return [
            SELECT Last_Pull_Status__c, Last_Pull_Message__c, Last_Pull_At__c, Next_Pull_At__c, Notify_User__c, Pull_Frequency__c
            FROM Cloud_Source__c
            WHERE Id = :sourceId
        ];
    }

    private static Map<String, Cloud_File__c> filesByPath() {
        Map<String, Cloud_File__c> result = new Map<String, Cloud_File__c>();
        for (Cloud_File__c f : [SELECT Object_Key__c, Status__c, Message__c, Import_Batch__c FROM Cloud_File__c LIMIT 100]) {
            result.put(f.Object_Key__c, f);
        }
        return result;
    }

    @IsTest
    static void newFilesAreTakenAndEverythingElseIsExplained() {
        FakeStorage fake = bucket();
        fake.put('inbox/', 'd41d8', '');
        fake.put('inbox/BARDER/harbour_like.csv', 'e1', HARBOUR_CSV);
        fake.put('inbox/KESTREL/export.csv', 'e2', HARBOUR_CSV + 'Megan Chen,1001\n');
        fake.put('inbox/loose.csv', 'e3', HARBOUR_CSV);
        fake.put('inbox/BARDER/notes.pdf', 'e4', 'pdf');
        fake.put('inbox/BARDER/huge.csv', 'e5', null);
        Cloud_Source__c src = source('Manual only');

        Test.startTest();
        CloudPullService.Result r = CloudPullService.pull(src.Id);
        Test.stopTest();

        Assert.areEqual(2, r.received, 'two dealer files');
        Assert.areEqual(3, r.refused, 'loose file, PDF and oversized file');
        Assert.areEqual(new List<String>{ 'inbox/BARDER/harbour_like.csv', 'inbox/KESTREL/export.csv' }, fake.reads, 'only what can be taken is downloaded');
        Map<String, Cloud_File__c> files = filesByPath();
        Assert.areEqual(5, files.size(), 'every file is remembered; the folder marker is not a file');
        Assert.isTrue(files.get('inbox/loose.csv').Message__c.contains('subfolder named with its code'), 'says why');
        Assert.isTrue(files.get('inbox/BARDER/notes.pdf').Message__c.contains('CSV and text'), 'says why');
        Assert.isTrue(files.get('inbox/BARDER/huge.csv').Message__c.contains('larger than'), 'says why');
        Map<String, String> statusByFirm = new Map<String, String>();
        for (Import_Batch__c b : [SELECT Source_Firm__c, Status__c FROM Import_Batch__c]) {
            statusByFirm.put(b.Source_Firm__c, b.Status__c);
        }
        Assert.areEqual(
            new Map<String, String>{ 'BARDER' => 'Mapping Review', 'KESTREL' => 'Mapping Review' },
            statusByFirm,
            'each dealer from its folder; both files read by one job (no profile for this layout yet)'
        );
        Cloud_Source__c after = reload(src.Id);
        Assert.areEqual('Succeeded', after.Last_Pull_Status__c, 'pulled');
        Assert.areEqual('2 new files taken, 3 refused.', after.Last_Pull_Message__c, 'in plain words');
        Assert.isNull(after.Next_Pull_At__c, 'manual only: no next pull');
    }

    @IsTest
    static void filesAlreadyTakenAreSkippedUntilTheyChange() {
        FakeStorage fake = bucket();
        fake.put('inbox/BARDER/a.csv', 'v1', HARBOUR_CSV);
        Cloud_Source__c src = source('Manual only');
        CloudPullService.pull(src.Id);
        fake.reads.clear();

        Test.startTest();
        CloudPullService.Result again = CloudPullService.pull(src.Id);
        Assert.areEqual(0, again.received, 'nothing new');
        Assert.isTrue(fake.reads.isEmpty(), 'nothing downloaded twice');
        Assert.areEqual('No new files.', reload(src.Id).Last_Pull_Message__c, 'said so');
        // The dealer replaces the file: a new version tag.
        fake.listed[0].etag = 'v2';
        fake.contents.put('inbox/BARDER/a.csv', Blob.valueOf(HARBOUR_CSV + 'Megan Chen,1001\n'));
        CloudPullService.Result replaced = CloudPullService.pull(src.Id);
        Test.stopTest();

        Assert.areEqual(1, replaced.received, 'the new version is taken');
        Assert.areEqual(2, [SELECT COUNT() FROM Cloud_File__c], 'one record per version');
        Assert.areEqual(2, [SELECT COUNT() FROM Import_Batch__c], 'two batches');
    }

    @IsTest
    static void theSameContentsUnderAnotherNameIsADuplicate() {
        FakeStorage fake = bucket();
        fake.put('inbox/BARDER/a.csv', 'v1', HARBOUR_CSV);
        // Files are taken in path order (as S3 lists them), so the later path is the duplicate.
        fake.put('inbox/BARDER/b resent.csv', 'v2', HARBOUR_CSV);
        Cloud_Source__c src = source('Manual only');

        Test.startTest();
        CloudPullService.Result r = CloudPullService.pull(src.Id);
        Test.stopTest();

        Assert.areEqual(1, r.received, 'one batch');
        Assert.areEqual(1, r.duplicates, 'one duplicate');
        Assert.areEqual(1, [SELECT COUNT() FROM Import_Batch__c], 'never read twice');
        Map<String, Cloud_File__c> files = filesByPath();
        Assert.areEqual('Received', files.get('inbox/BARDER/a.csv').Status__c, 'the first is taken');
        Assert.areEqual('Duplicate', files.get('inbox/BARDER/b resent.csv').Status__c, 'recorded');
        Assert.areEqual(
            files.get('inbox/BARDER/a.csv').Import_Batch__c,
            files.get('inbox/BARDER/b resent.csv').Import_Batch__c,
            'pointing at the earlier batch'
        );
    }

    @IsTest
    static void aFailedDownloadIsTriedAgain() {
        FakeStorage fake = bucket();
        fake.put('inbox/BARDER/a.csv', 'v1', HARBOUR_CSV);
        fake.unreadable.add('inbox/BARDER/a.csv');
        Cloud_Source__c src = source('Manual only');

        Test.startTest();
        CloudPullService.Result first = CloudPullService.pull(src.Id);
        Assert.areEqual(1, first.failed, 'failed');
        Assert.areEqual('Failed', filesByPath().get('inbox/BARDER/a.csv').Status__c, 'recorded as failed');
        Assert.isTrue(reload(src.Id).Last_Pull_Message__c.contains('1 failed and will be tried again'), 'said so');
        fake.unreadable.clear();
        CloudPullService.Result second = CloudPullService.pull(src.Id);
        Test.stopTest();

        Assert.areEqual(1, second.received, 'taken on the next pull');
        Assert.areEqual(1, [SELECT COUNT() FROM Cloud_File__c], 'the same record, updated');
        Assert.areEqual('Received', filesByPath().get('inbox/BARDER/a.csv').Status__c, 'now received');
    }

    @IsTest
    static void aPullThatCannotReachTheBucketSaysWhy() {
        FakeStorage fake = bucket();
        fake.listFails = true;
        Cloud_Source__c src = source('Hourly');

        Test.startTest();
        CloudPullService.Result r = CloudPullService.pull(src.Id);
        Test.stopTest();

        Cloud_Source__c after = reload(src.Id);
        Assert.areEqual('Failed', after.Last_Pull_Status__c, 'failed');
        Assert.isTrue(after.Last_Pull_Message__c.contains('AccessDenied'), 'with the reason: ' + after.Last_Pull_Message__c);
        Assert.isNotNull(after.Next_Pull_At__c, 'still on its schedule');
        Assert.areEqual(0, [SELECT COUNT() FROM Cloud_File__c], 'nothing recorded');
        Assert.isNotNull(r.failure, 'reported');
    }

    @IsTest
    static void onlyTheFirstFilesOfABigDropAreTakenAtOnce() {
        FakeStorage fake = bucket();
        CloudPullService.maxFilesPerPull = 2;
        for (Integer i = 1; i <= 3; i++) {
            fake.put('inbox/BARDER/file' + i + '.csv', 'v' + i, HARBOUR_CSV + 'Advisor ' + i + ',100' + i + '\n');
        }
        Cloud_Source__c src = source('Manual only');

        Test.startTest();
        CloudPullService.Result r = CloudPullService.pull(src.Id);
        Test.stopTest();

        Assert.areEqual(2, r.received, 'two now');
        Assert.areEqual(1, r.waiting, 'one waits');
        Assert.areEqual('2 new files taken. 1 more file waits for the next pull.', reload(src.Id).Last_Pull_Message__c, 'said so');
    }

    @IsTest
    static void theScheduleSetsTheNextPull() {
        Datetime nine = Datetime.newInstance(Date.newInstance(2026, 11, 3), Time.newInstance(9, 10, 0, 0));
        Assert.areEqual(nine.addMinutes(15), CloudPullService.nextPull('Every 15 minutes', null, true, nine), '15 minutes');
        Assert.areEqual(nine.addHours(1), CloudPullService.nextPull('Hourly', null, true, nine), 'hourly');
        Assert.areEqual(nine.addHours(4), CloudPullService.nextPull('Every 4 hours', null, true, nine), 'every 4 hours');
        Assert.areEqual(
            Datetime.newInstance(Date.newInstance(2026, 11, 3), Time.newInstance(18, 0, 0, 0)),
            CloudPullService.nextPull('Daily', 18, true, nine),
            'later today'
        );
        Assert.areEqual(
            Datetime.newInstance(Date.newInstance(2026, 11, 4), Time.newInstance(6, 0, 0, 0)),
            CloudPullService.nextPull('Daily', 6, true, nine),
            'tomorrow when today\'s hour has passed'
        );
        Assert.isNull(CloudPullService.nextPull('Manual only', null, true, nine), 'manual');
        Assert.isNull(CloudPullService.nextPull('Hourly', null, false, nine), 'inactive');

        Cloud_Source__c src = source('Hourly');
        Datetime next = reload(src.Id).Next_Pull_At__c;
        Assert.isTrue(next > System.now().addMinutes(55) && next <= System.now().addMinutes(61), 'set when saved: ' + next);
        update new Cloud_Source__c(Id = src.Id, Active__c = false);
        Assert.isNull(reload(src.Id).Next_Pull_At__c, 'cleared when turned off');
    }

    @IsTest
    static void theSweeperStartsDueSources() {
        bucket();
        Cloud_Source__c due = source('Every 15 minutes');
        Cloud_Source__c later = source('Daily');
        SystemWriter.updateOne(new Cloud_Source__c(Id = due.Id, Next_Pull_At__c = System.now().addMinutes(-1)));

        Test.startTest();
        StrandedWorkSweeper.Result r = StrandedWorkSweeper.sweep();
        Assert.areEqual(1, r.pullsStarted, 'only the due source');
        Assert.areEqual('Pulling', reload(due.Id).Last_Pull_Status__c, 'shown as pulling');
        Assert.isNull(reload(later.Id).Last_Pull_Status__c, 'the other waits for its hour');
        Test.stopTest();
    }

    @IsTest
    static void aReviewerPullsNowAndChoosesHowOften() {
        FakeStorage fake = bucket();
        fake.put('inbox/BARDER/a.csv', 'v1', HARBOUR_CSV);
        Cloud_Source__c src = source('Manual only');
        Cloud_Source__c off = new Cloud_Source__c(
            Name = 'Old drop',
            Provider__c = 'Amazon S3',
            Named_Credential__c = 'Trade_View_S3',
            Pull_Frequency__c = 'Manual only'
        );
        insert off;
        User reviewer = TestDataFactory.userWithPermissionSets(new List<String>{ 'Trade_Import_Reviewer' });

        System.runAs(reviewer) {
            ReviewController.setPullSchedule(src.Id, 'Daily', 7);
            Cloud_Source__c scheduled = reload(src.Id);
            Assert.areEqual('Daily', scheduled.Pull_Frequency__c, 'saved');
            Assert.isNotNull(scheduled.Next_Pull_At__c, 'next pull set');
            Assert.areEqual(2, ReviewController.getQueue('all').cloudSources.size(), 'both folders listed');

            Test.startTest();
            ReviewController.pullNow(src.Id);
            Cloud_Source__c pulling = reload(src.Id);
            Assert.areEqual('Pulling', pulling.Last_Pull_Status__c, 'started');
            Assert.areEqual(reviewer.Id, pulling.Notify_User__c, 'the reviewer is told about the files it takes');
            Assert.isTrue(failureOf(src.Id).contains('being checked now'), 'not twice at once');
            Assert.isTrue(failureOf(off.Id).contains('not active'), 'an inactive folder is not pulled');
            Test.stopTest();
        }
    }

    @IsTest
    static void whoeverClickedPullNowHearsAboutEachFile() {
        FakeStorage fake = bucket();
        fake.put('inbox/BARDER/a.csv', 'v1', HARBOUR_CSV);
        Cloud_Source__c src = source('Manual only');
        SystemWriter.updateOne(new Cloud_Source__c(Id = src.Id, Notify_User__c = UserInfo.getUserId()));

        Test.startTest();
        CloudPullService.pull(src.Id);
        Import_Batch__c waiting = [SELECT Id, Notify_User__c FROM Import_Batch__c];
        Assert.areEqual(UserInfo.getUserId(), waiting.Notify_User__c, 'the file is marked for whoever clicked Pull now');
        Assert.isNull(reload(src.Id).Notify_User__c, 'and the source forgets them');
        Test.stopTest();

        Import_Batch__c told = [SELECT Status__c, Notify_User__c FROM Import_Batch__c WHERE Id = :waiting.Id];
        Assert.areEqual('Mapping Review', told.Status__c, 'read');
        Assert.isNull(told.Notify_User__c, 'and they have had their bell');
    }

    private static String failureOf(Id sourceId) {
        try {
            ReviewController.pullNow(sourceId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return 'no error';
    }
}
