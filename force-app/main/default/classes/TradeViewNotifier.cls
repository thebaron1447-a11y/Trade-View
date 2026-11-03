/**
 * Tells people when background work finishes (phase 4e.2), so the Trade Review page no longer has to keep asking.
 *
 *   - changed(): publishes a Trade View Update platform event after the transaction commits. An open Trade Review page
 *     listens for it (lightning/empApi) and refreshes once. It carries only what changed and its record Id.
 *   - fileSettled(): sends a bell notification (custom notification type Trade_View) to the person waiting on a file,
 *     the one who uploaded it or clicked Load file (Import Batch Notify User), then clears Notify User so they hear once.
 *     Files the push job sends have no Notify User, so nobody gets a bell for those.
 *
 * Neither ever stops the work it reports on: a failure to publish or send is written to the debug log and dropped.
 */
// Debug lines run only when a publish or send fails, which must never stop the work being reported on.
@SuppressWarnings('PMD.AvoidDebugStatements')
public with sharing class TradeViewNotifier {
    public static final String KIND_FILE = 'File';
    public static final String KIND_ROWS = 'Rows';
    public static final String KIND_CLAUDE = 'Claude';
    public static final String KIND_LOAD = 'Load';
    public static final String NOTIFICATION_TYPE = 'Trade_View';
    /** What the bell says, by moment. */
    public static final String MOMENT_READ = 'read';
    public static final String MOMENT_MATCHED = 'matched';
    public static final String MOMENT_LOADED = 'loaded';

    /** Bell notifications built in this transaction, for tests (they are sent the same way in tests). */
    @TestVisible
    private static List<Sent> sent = new List<Sent>();

    public class Sent {
        public Id userId;
        public Id batchId;
        public String title;
        public String body;
    }

    /** Publishes one update. Safe to call anywhere; never throws. */
    public static void changed(String kind, Id recordId) {
        try {
            EventBus.publish(new Trade_View_Update__e(Kind__c = kind, Record_Id__c = recordId));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Trade View update not published: ' + e.getMessage());
        }
    }

    /**
     * After a step that can leave a file waiting on a person: reading it (Mapping Review or Failed), matching it
     * (Pending Review) or loading it (Completed, or Pending Review with rows still waiting, or a stopped load).
     * Sends the bell for files whose Notify User is set, then clears it. Files still being worked on are skipped.
     */
    public static void fileSettled(Set<Id> batchIds, String moment) {
        if (batchIds == null || batchIds.isEmpty()) {
            return;
        }
        try {
            List<Import_Batch__c> waiting = [
                SELECT
                    Id,
                    Name,
                    Status__c,
                    Source_Firm__c,
                    Source_File_Name__c,
                    Notify_User__c,
                    Row_Count__c,
                    Matched_Row_Count__c,
                    Review_Row_Count__c,
                    Held_Row_Count__c,
                    Error_Row_Count__c,
                    Loaded_Row_Count__c,
                    Error_Message__c
                FROM Import_Batch__c
                WHERE Id IN :batchIds AND Notify_User__c != NULL
                WITH USER_MODE
            ];
            List<Import_Batch__c> cleared = new List<Import_Batch__c>();
            for (Import_Batch__c b : waiting) {
                Sent s = message(b, moment);
                if (s == null) {
                    continue;
                }
                send(s);
                cleared.add(new Import_Batch__c(Id = b.Id, Notify_User__c = null));
            }
            SystemWriter.updateAll(cleared);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Trade View notification not sent: ' + e.getMessage());
        }
    }

    /** The bell for a file at this moment, or null when it is still being worked on. */
    @TestVisible
    private static Sent message(Import_Batch__c b, String moment) {
        String file = (b.Source_Firm__c == null ? '' : b.Source_Firm__c + ' · ') + (b.Source_File_Name__c == null ? b.Name : b.Source_File_Name__c);
        Sent s = new Sent();
        s.userId = b.Notify_User__c;
        s.batchId = b.Id;
        String status = b.Status__c;
        if (status == ImportBatchProcessor.STATUS_FAILED) {
            s.title = 'File could not be read: ' + file;
            s.body = String.isBlank(b.Error_Message__c) ? 'Open Recent Files in Trade Review for details.' : b.Error_Message__c;
        } else if (status == ImportBatchProcessor.STATUS_MAPPING_REVIEW) {
            s.title = 'New file format: ' + file;
            s.body = 'The file\'s columns need a mapping before its rows can be read. Open New File Format in Trade Review.';
        } else if (moment == MOMENT_MATCHED && status == TradeMatcher.STATUS_PENDING_REVIEW) {
            s.title = 'File ready: ' + file;
            s.body =
                rowsText(b.Row_Count__c) +
                ': ' +
                count(b.Matched_Row_Count__c, 'matched') +
                ', ' +
                count(b.Review_Row_Count__c, 'to review') +
                ', ' +
                count(b.Held_Row_Count__c, 'held') +
                ', ' +
                count(b.Error_Row_Count__c, 'invalid') +
                '.';
        } else if (moment == MOMENT_LOADED && status == TradeLoader.STATUS_COMPLETED) {
            s.title = 'File booked: ' + file;
            s.body = rowsText(b.Loaded_Row_Count__c) + ' loaded. Nothing in the file is waiting.';
        } else if (moment == MOMENT_LOADED && status == TradeMatcher.STATUS_PENDING_REVIEW) {
            Boolean stopped = String.isNotBlank(b.Error_Message__c);
            s.title = (stopped ? 'Loading stopped: ' : 'Rows loaded: ') + file;
            s.body = stopped
                ? b.Error_Message__c
                : rowsText(b.Loaded_Row_Count__c) + ' loaded so far. Rows still in review or on hold load once they are decided.';
        } else {
            return null;
        }
        s.title = s.title.abbreviate(250);
        s.body = s.body.abbreviate(750);
        return s;
    }

    private static void send(Sent s) {
        sent.add(s);
        Id typeId = notificationTypeId();
        if (typeId == null) {
            return;
        }
        Messaging.CustomNotification n = new Messaging.CustomNotification();
        n.setNotificationTypeId(typeId);
        n.setTitle(s.title);
        n.setBody(s.body);
        // Opens the Trade Review tab, where the file is in Recent Files.
        n.setTargetPageRef(
            JSON.serialize(new Map<String, Object>{ 'type' => 'standard__navItemPage', 'attributes' => new Map<String, Object>{ 'apiName' => 'Trade_Review' } })
        );
        n.send(new Set<String>{ s.userId });
    }

    private static Id typeId;
    private static Boolean typeLooked = false;

    private static Id notificationTypeId() {
        if (!typeLooked) {
            typeLooked = true;
            // Setup data, read in system mode: the notification type is not a record a user is granted.
            List<CustomNotificationType> types = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = :NOTIFICATION_TYPE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            typeId = types.isEmpty() ? null : types[0].Id;
        }
        return typeId;
    }

    private static String rowsText(Decimal n) {
        Integer k = n == null ? 0 : n.intValue();
        return String.valueOf(k) + (k == 1 ? ' row' : ' rows');
    }

    private static String count(Decimal n, String what) {
        return String.valueOf(n == null ? 0 : n.intValue()) + ' ' + what;
    }
}
