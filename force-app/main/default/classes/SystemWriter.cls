/**
 * The one place background steps save fields that people must not edit by hand: match results, Claude's answers,
 * counts, decision and hold stamps, and the records a roster approval creates or ends (audit F-01).
 *
 * Callers are services that have already checked what they save; the review app and the REST intake stay in user
 * mode for everything a person decides. Saves here run in system mode for field and object access (sharing still
 * follows this class's with sharing), so the Reviewer and Integration permission sets can keep these fields
 * read-only. While a save runs, isActive() is true: the staging row guard lets system-owned fields change only then.
 */
public with sharing class SystemWriter {
    private static Boolean running = false;

    /** True while a system save (and any trigger it fires) is in progress. */
    public static Boolean isActive() {
        return running;
    }

    public static void insertAll(List<SObject> records) {
        save(records, true);
    }

    public static void updateAll(List<SObject> records) {
        save(records, false);
    }

    public static void insertOne(SObject record) {
        save(new List<SObject>{ record }, true);
    }

    public static void updateOne(SObject record) {
        save(new List<SObject>{ record }, false);
    }

    /** All or none, like DML statements; a nested save (from a trigger) keeps the enclosing save's state when it ends. */
    private static void save(List<SObject> records, Boolean isInsert) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Boolean wasRunning = running;
        running = true;
        try {
            if (isInsert) {
                Database.insert(records, true, AccessLevel.SYSTEM_MODE);
            } else {
                Database.update(records, true, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            running = wasRunning;
        }
    }
}
