/**
 * Pulls dealer files from cloud storage (phase 4c): Amazon S3 first, behind the CloudStorage interface so Azure Blob
 * and Google Cloud Storage can follow.
 *
 * A pull lists the source's folder, skips files already taken (Cloud File records: path plus version tag), and reads
 * up to MAX_FILES_PER_PULL new ones; any more wait for the next pull. Each dealer's files are in a subfolder named with
 * its code, unless the source names one dealer. Files over the intake limit, outside a dealer folder or not CSV or
 * text are refused without downloading. Every file read goes through FileIntakeService, so duplicates and limits work
 * exactly as for the push job and uploads, and the files are then read together by one ImportBatchProcessor job.
 * The bucket is only read: nothing is moved or deleted, so the access key can be read-only.
 *
 * All callouts happen before any save (Apex refuses a callout after uncommitted work). A failure to list or connect
 * marks the source Failed with the reason and keeps it on its schedule; a failure on one file is recorded on its Cloud
 * File and that file is tried again next time.
 *
 * Scheduling: Pull Frequency and Pull Hour set Next Pull At (CloudSourceTrigger, and after each pull). The stranded
 * work sweeper, every 15 minutes, starts each active source that is due. Pull now in Trade Review starts one at once.
 */
public with sharing class CloudPullService {
    public class CloudException extends Exception {
    }

    /** One file as the provider lists it. */
    public class CloudObject {
        public String key;
        public String etag;
        public Long size;
    }

    /** What a pull did. */
    public class Result {
        public Integer received = 0;
        public Integer duplicates = 0;
        public Integer refused = 0;
        public Integer failed = 0;
        public Integer waiting = 0;
        public List<Id> batchIds = new List<Id>();
        public String failure;
    }

    public static final String PROVIDER_S3 = 'Amazon S3';
    public static final String FREQ_MANUAL = 'Manual only';
    public static final String FREQ_15 = 'Every 15 minutes';
    public static final String FREQ_HOURLY = 'Hourly';
    public static final String FREQ_4H = 'Every 4 hours';
    public static final String FREQ_DAILY = 'Daily';
    public static final String PULLING = 'Pulling';
    public static final String SUCCEEDED = 'Succeeded';
    public static final String FAILED = 'Failed';
    public static final String FILE_RECEIVED = 'Received';
    public static final String FILE_DUPLICATE = 'Duplicate';
    public static final String FILE_REFUSED = 'Refused';
    public static final String FILE_FAILED = 'Failed';

    @TestVisible
    private static Integer maxFilesPerPull = 10;
    /** Tests replace the provider with a fake. */
    @TestVisible
    private static CloudStorage storageOverride;
    private static final Pattern CREDENTIAL_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,79}$');
    private static final Set<String> FILE_TYPES = new Set<String>{ 'csv', 'txt' };

    public static CloudStorage storageFor(String provider) {
        if (storageOverride != null) {
            return storageOverride;
        }
        if (provider == PROVIDER_S3) {
            return new S3Storage();
        }
        throw new CloudException('Trade View cannot read ' + provider + ' yet.');
    }

    // ================================================================== schedule

    /** When a source is next due after fromTime, or null for Manual only and inactive sources. Daily is local time. */
    public static Datetime nextPull(String frequency, Decimal hour, Boolean active, Datetime fromTime) {
        if (active != true || frequency == null || frequency == FREQ_MANUAL) {
            return null;
        }
        if (frequency == FREQ_15) {
            return fromTime.addMinutes(15);
        }
        if (frequency == FREQ_HOURLY) {
            return fromTime.addHours(1);
        }
        if (frequency == FREQ_4H) {
            return fromTime.addHours(4);
        }
        if (frequency == FREQ_DAILY) {
            Integer h = hour == null ? 0 : Math.max(0, Math.min(23, hour.intValue()));
            Datetime sameDay = Datetime.newInstance(fromTime.date(), Time.newInstance(h, 0, 0, 0));
            return sameDay > fromTime ? sameDay : sameDay.addDays(1);
        }
        return null;
    }

    /** Before insert and update: a new or changed schedule sets Next Pull At from now. */
    public static void beforeSave(List<Cloud_Source__c> sources, Map<Id, Cloud_Source__c> previous) {
        Datetime now = System.now();
        for (Cloud_Source__c s : sources) {
            Cloud_Source__c before = previous == null ? null : previous.get(s.Id);
            Boolean changed =
                before == null ||
                s.Pull_Frequency__c != before.Pull_Frequency__c ||
                s.Pull_Hour__c != before.Pull_Hour__c ||
                s.Active__c != before.Active__c;
            if (changed) {
                s.Next_Pull_At__c = nextPull(s.Pull_Frequency__c, s.Pull_Hour__c, s.Active__c, now);
            }
        }
    }

    /** Active sources whose next pull has come. */
    public static List<Cloud_Source__c> dueSources(Datetime asOf, Integer max) {
        return [
            SELECT Id
            FROM Cloud_Source__c
            WHERE Active__c = TRUE AND Next_Pull_At__c != NULL AND Next_Pull_At__c <= :asOf
            WITH USER_MODE
            ORDER BY Next_Pull_At__c
            LIMIT :max
        ];
    }

    // ================================================================== pull

    private class Candidate {
        public CloudObject obj;
        public String fileKey;
        public String firm;
        public String fileName;
        public String status;
        public String message;
        public Blob content;
    }

    /** Pulls one source now. Returns what it did; the source records it too (Last Pull At, Status, Message). */
    public static Result pull(Id sourceId) {
        Result r = new Result();
        List<Cloud_Source__c> found = [
            SELECT Id, Name, Provider__c, Named_Credential__c, Folder__c, Source_Firm__c, Active__c, Pull_Frequency__c, Pull_Hour__c, Notify_User__c
            FROM Cloud_Source__c
            WHERE Id = :sourceId
            WITH USER_MODE
            LIMIT 1
        ];
        if (found.isEmpty() || found[0].Active__c != true) {
            return r;
        }
        Cloud_Source__c src = found[0];

        // Callouts first: list, then read the new files.
        List<Candidate> candidates = new List<Candidate>();
        Map<String, Id> retry = new Map<String, Id>();
        try {
            if (String.isBlank(src.Named_Credential__c) || !CREDENTIAL_NAME.matcher(src.Named_Credential__c).matches()) {
                throw new CloudException('The Named Credential must be an API name (letters, numbers and underscores).');
            }
            CloudStorage store = storageFor(src.Provider__c);
            Map<String, Candidate> byKey = new Map<String, Candidate>();
            for (CloudObject o : store.listFiles(src)) {
                if (o.key == null || o.key.endsWith('/')) {
                    continue; // a folder marker
                }
                Candidate c = new Candidate();
                c.obj = o;
                c.fileKey = fileKey(src.Id, o);
                byKey.put(c.fileKey, c);
            }
            for (Cloud_File__c f : [SELECT Id, File_Key__c, Status__c FROM Cloud_File__c WHERE File_Key__c IN :byKey.keySet() WITH USER_MODE]) {
                if (f.Status__c == FILE_FAILED) {
                    retry.put(f.File_Key__c, f.Id);
                } else {
                    byKey.remove(f.File_Key__c);
                }
            }
            List<Candidate> ordered = new List<Candidate>(byKey.values());
            sortByPath(ordered);
            Integer downloads = 0;
            for (Candidate c : ordered) {
                place(src, c);
                if (c.status == FILE_REFUSED) {
                    candidates.add(c);
                    continue;
                }
                if (downloads >= maxFilesPerPull) {
                    r.waiting++;
                    continue;
                }
                downloads++;
                try {
                    c.content = store.readFile(src, c.obj.key);
                } catch (Exception e) {
                    c.status = FILE_FAILED;
                    c.message = ('Could not read the file: ' + e.getMessage()).abbreviate(2000);
                }
                candidates.add(c);
            }
        } catch (Exception e) {
            r.failure = e.getMessage();
        }

        // Then the saves.
        if (r.failure != null) {
            finish(src, FAILED, ('The pull failed: ' + r.failure).abbreviate(2000));
            return r;
        }
        List<Cloud_File__c> inserts = new List<Cloud_File__c>();
        List<Cloud_File__c> updates = new List<Cloud_File__c>();
        List<Import_Batch__c> notify = new List<Import_Batch__c>();
        for (Candidate c : candidates) {
            Id batchId;
            if (c.status == null) {
                try {
                    FileIntakeService.Receipt receipt = FileIntakeService.receive(c.firm, c.fileName, c.content, null, false);
                    batchId = receipt.batchId;
                    c.status = receipt.duplicate ? FILE_DUPLICATE : FILE_RECEIVED;
                    c.message = receipt.message;
                    if (!receipt.duplicate && receipt.batchId != null) {
                        r.batchIds.add(receipt.batchId);
                        if (src.Notify_User__c != null) {
                            notify.add(new Import_Batch__c(Id = receipt.batchId, Notify_User__c = src.Notify_User__c));
                        }
                    }
                } catch (FileIntakeService.IntakeException e) {
                    c.status = FILE_REFUSED;
                    c.message = e.getMessage();
                } catch (Exception e) {
                    c.status = FILE_FAILED;
                    c.message = ('The file could not be received: ' + e.getMessage()).abbreviate(2000);
                }
            }
            tally(r, c.status);
            Cloud_File__c record = new Cloud_File__c(
                Id = retry.get(c.fileKey),
                Object_Key__c = c.obj.key.abbreviate(255),
                ETag__c = c.obj.etag == null ? null : c.obj.etag.abbreviate(100),
                File_Key__c = c.fileKey,
                Size_Bytes__c = c.obj.size,
                Status__c = c.status,
                Message__c = c.message == null ? null : c.message.abbreviate(2000),
                Import_Batch__c = batchId
            );
            if (record.Id == null) {
                record.Cloud_Source__c = src.Id;
                inserts.add(record);
            } else {
                updates.add(record);
            }
        }
        SystemWriter.insertAll(inserts);
        SystemWriter.updateAll(updates);
        SystemWriter.updateAll(notify);
        finish(src, SUCCEEDED, summary(r));
        queueReading(r.batchIds);
        return r;
    }

    /** Which dealer a file belongs to and what it is called; refuses what the intake must not see. */
    private static void place(Cloud_Source__c src, Candidate c) {
        String key = c.obj.key;
        String folder = String.isBlank(src.Folder__c) ? '' : src.Folder__c;
        String rest = folder != '' && key.startsWith(folder) ? key.substring(folder.length()) : key;
        rest = rest.removeStart('/');
        List<String> parts = rest.split('/');
        c.fileName = parts[parts.size() - 1];
        if (String.isNotBlank(src.Source_Firm__c)) {
            c.firm = src.Source_Firm__c;
        } else if (parts.size() >= 2) {
            c.firm = parts[parts.size() - 2];
        }
        String extension = c.fileName.contains('.') ? c.fileName.substringAfterLast('.').toLowerCase() : '';
        if (c.firm == null) {
            refuse(c, 'Not in a dealer folder. Put each dealer\'s files in a subfolder named with its code, for example BARDER/' + c.fileName + '.');
        } else if (!FILE_TYPES.contains(extension)) {
            refuse(c, 'Only CSV and text files are read.');
        } else if (c.obj.size != null && c.obj.size > FileIntakeService.MAX_FILE_BYTES) {
            refuse(c, 'The file is larger than ' + (FileIntakeService.MAX_FILE_BYTES / 1024) + ' KB. Ask the sender to split it.');
        }
    }

    private static void refuse(Candidate c, String why) {
        c.status = FILE_REFUSED;
        c.message = why;
    }

    private static void tally(Result r, String status) {
        if (status == FILE_RECEIVED) {
            r.received++;
        } else if (status == FILE_DUPLICATE) {
            r.duplicates++;
        } else if (status == FILE_REFUSED) {
            r.refused++;
        } else {
            r.failed++;
        }
    }

    /** "3 new files taken, 1 already received, 1 refused. 2 more wait for the next pull." */
    @TestVisible
    private static String summary(Result r) {
        List<String> parts = new List<String>();
        parts.add(r.received == 0 ? 'No new files' : count(r.received, 'new file') + ' taken');
        if (r.duplicates > 0) {
            parts.add(String.valueOf(r.duplicates) + ' already received');
        }
        if (r.refused > 0) {
            parts.add(String.valueOf(r.refused) + ' refused');
        }
        if (r.failed > 0) {
            parts.add(String.valueOf(r.failed) + ' failed and will be tried again');
        }
        String line = String.join(parts, ', ') + '.';
        if (r.waiting > 0) {
            line += ' ' + count(r.waiting, 'more file') + (r.waiting == 1 ? ' waits' : ' wait') + ' for the next pull.';
        }
        return line;
    }

    private static String count(Integer n, String noun) {
        return String.valueOf(n) + ' ' + noun + (n == 1 ? '' : 's');
    }

    private static void finish(Cloud_Source__c src, String status, String message) {
        Datetime now = System.now();
        SystemWriter.updateOne(
            new Cloud_Source__c(
                Id = src.Id,
                Last_Pull_At__c = now,
                Last_Pull_Status__c = status,
                Last_Pull_Message__c = message,
                Next_Pull_At__c = nextPull(src.Pull_Frequency__c, src.Pull_Hour__c, src.Active__c, now),
                Notify_User__c = null
            )
        );
        TradeViewNotifier.changed(TradeViewNotifier.KIND_PULL, src.Id);
    }

    /** One job reads every file taken, then matches them together. In a test's queued job it cannot queue another. */
    private static void queueReading(List<Id> batchIds) {
        if (batchIds.isEmpty() || (System.isQueueable() && Test.isRunningTest()) || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        System.enqueueJob(new ImportBatchProcessor(batchIds));
    }

    /** Source Id plus a SHA-256 of the path and version tag: one Cloud File per version of each file. */
    @TestVisible
    private static String fileKey(Id sourceId, CloudObject o) {
        String digest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(o.key + '|' + (o.etag == null ? '' : o.etag))));
        return String.valueOf(sourceId) + '|' + digest;
    }

    /** By path, so files are taken in a predictable order (dealers' file names usually carry the date). */
    private static void sortByPath(List<Candidate> items) {
        Map<String, List<Candidate>> byPath = new Map<String, List<Candidate>>();
        for (Candidate c : items) {
            if (!byPath.containsKey(c.obj.key)) {
                byPath.put(c.obj.key, new List<Candidate>());
            }
            byPath.get(c.obj.key).add(c);
        }
        List<String> paths = new List<String>(byPath.keySet());
        paths.sort();
        items.clear();
        for (String p : paths) {
            items.addAll(byPath.get(p));
        }
    }
}
