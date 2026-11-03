/**
 * Books a file's matched rows (phase 4e): each Trade row becomes a Trade with one Trade Allocation per credited
 * advisor, and each AUM row becomes an AUM Balance with AUM Allocations. Started by Load file in Trade Review
 * (ReviewController.loadFile), which sets the file to Loading.
 *
 * Credit follows matching: a row with a Credited Advisor gives that advisor 100%; a team row splits by the shares
 * active on the row's date, which must total 100%. If a team's shares changed after matching so they no longer total
 * 100% (or a trade has lost its fund), the row is not loaded: it goes back to Pending and matching puts it on hold or
 * in review, as it would for a new row. Rows still waiting (in review, on hold) are left for a later Load.
 *
 * Loading is safe to repeat: only rows with no Loaded At are taken, a Trade's Load Key (the row Id) is unique, and an
 * AUM Balance is keyed by code, fund and date, so a balance sent again replaces the earlier one and its allocations.
 * Rows load CHUNK at a time, one queued job per chunk; each chunk saves all or nothing. When no matched rows are left,
 * the file is Completed if nothing is waiting, else back to Pending Review. If a job cannot queue the next one, the
 * stranded work sweeper restarts the load.
 */
public with sharing class TradeLoader implements Queueable {
    public static final String STATUS_LOADING = 'Loading';
    public static final String STATUS_COMPLETED = 'Completed';
    /** Row statuses that mean a row is still waiting on matching or a person. */
    public static final Set<String> WAITING = new Set<String>{ TradeMatcher.PENDING, TradeMatcher.REVIEW, TradeMatcher.HELD };
    /** Row types a load books. Code Roster rows change assignments when they are approved and have nothing to load. */
    public static final Set<String> LOADABLE_TYPES = new Set<String>{ TradeRowNormalizer.ROW_TRADE, TradeRowNormalizer.ROW_AUM };
    public static final Integer CHUNK = 200;
    @TestVisible
    private static Integer chunkSize = CHUNK;
    private static final String ALL_FUNDS = 'ALL';

    private final Id batchId;

    public TradeLoader(Id batchId) {
        this.batchId = batchId;
    }

    public void execute(QueueableContext context) {
        if (loadNext(batchId) && !Test.isRunningTest() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new TradeLoader(batchId));
        }
    }

    /** What one chunk did. */
    public class Result {
        public Integer trades = 0;
        public Integer balances = 0;
        public Integer sentBack = 0;
        public Boolean more = false;
    }

    @TestVisible
    private static Result lastResult;

    /** Loads the next chunk of a Loading file. Returns true while more matched rows are waiting to load. */
    public static Boolean loadNext(Id batchId) {
        lastResult = new Result();
        List<Import_Batch__c> found = [SELECT Id, Status__c FROM Import_Batch__c WHERE Id = :batchId WITH USER_MODE LIMIT 1 FOR UPDATE];
        if (found.isEmpty() || found[0].Status__c != STATUS_LOADING) {
            return false;
        }
        List<Import_Staging_Row__c> rows = loadableRows(batchId, chunkSize + 1);
        Boolean more = rows.size() > chunkSize;
        if (more) {
            rows.remove(chunkSize);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            load(rows, lastResult);
            if (more) {
                SystemWriter.updateOne(new Import_Batch__c(Id = batchId, Loaded_Row_Count__c = loadedCount(batchId)));
            } else {
                finish(batchId);
            }
        } catch (Exception e) {
            Database.rollback(sp);
            // The file stays usable: nothing in this chunk was saved, and Load file can be clicked again once fixed.
            SystemWriter.updateOne(
                new Import_Batch__c(
                    Id = batchId,
                    Status__c = TradeMatcher.STATUS_PENDING_REVIEW,
                    Error_Message__c = ('Loading stopped and nothing in the last ' + rows.size() + ' rows was saved: ' + e.getMessage()).abbreviate(5000)
                )
            );
            TradeViewNotifier.changed(TradeViewNotifier.KIND_LOAD, batchId);
            TradeViewNotifier.fileSettled(new Set<Id>{ batchId }, TradeViewNotifier.MOMENT_LOADED);
            return false;
        }
        TradeViewNotifier.changed(TradeViewNotifier.KIND_LOAD, batchId);
        lastResult.more = more;
        return more;
    }

    /** Matched Trade and AUM rows of a file that are not loaded yet, in file order. */
    public static List<Import_Staging_Row__c> loadableRows(Id batchId, Integer max) {
        return [
            SELECT
                Id,
                Import_Batch__c,
                Row_Number__c,
                Row_Type__c,
                Matched_Rep_Code__c,
                Matched_Fund__c,
                Credited_Advisor__c,
                Trade_Date__c,
                Transaction_Type__c,
                Amount__c,
                Match_Notes__c
            FROM Import_Staging_Row__c
            WHERE
                Import_Batch__c = :batchId
                AND Match_Status__c = :TradeMatcher.MATCHED
                AND Row_Type__c IN :LOADABLE_TYPES
                AND Loaded_At__c = NULL
                AND Has_Errors__c = FALSE
            WITH USER_MODE
            ORDER BY Row_Number__c
            LIMIT :max
        ];
    }

    /** How many rows of a file are ready for Load file. */
    public static Integer loadableCount(Id batchId) {
        return [
            SELECT COUNT()
            FROM Import_Staging_Row__c
            WHERE
                Import_Batch__c = :batchId
                AND Match_Status__c = :TradeMatcher.MATCHED
                AND Row_Type__c IN :LOADABLE_TYPES
                AND Loaded_At__c = NULL
                AND Has_Errors__c = FALSE
            WITH USER_MODE
        ];
    }

    // ================================================================== booking

    private class Booking {
        public Import_Staging_Row__c row;
        public List<TradeAllocator.Share> shares;
        public String key;
    }

    @TestVisible
    private static void load(List<Import_Staging_Row__c> rows, Result result) {
        if (rows.isEmpty()) {
            return;
        }
        Map<Id, List<Rep_Code_Assignment__c>> byCode = assignments(rows);
        List<Booking> trades = new List<Booking>();
        Map<String, Booking> balances = new Map<String, Booking>();
        List<Import_Staging_Row__c> aumRows = new List<Import_Staging_Row__c>();
        List<Import_Staging_Row__c> changes = new List<Import_Staging_Row__c>();
        for (Import_Staging_Row__c row : rows) {
            String problem;
            List<TradeAllocator.Share> shares;
            if (row.Matched_Rep_Code__c == null || row.Trade_Date__c == null || row.Amount__c == null) {
                problem = 'the row has no matched code, date or amount';
            } else if (row.Row_Type__c == TradeRowNormalizer.ROW_TRADE && row.Matched_Fund__c == null) {
                problem = 'the trade has no matched fund';
            } else {
                shares = sharesOn(row, byCode.get(row.Matched_Rep_Code__c));
                if (shares == null) {
                    problem = 'the shares on this code on ' + row.Trade_Date__c.format() + ' no longer total 100%';
                }
            }
            if (problem != null) {
                changes.add(sendBack(row, problem));
                result.sentBack++;
                continue;
            }
            Booking b = new Booking();
            b.row = row;
            b.shares = shares;
            if (row.Row_Type__c == TradeRowNormalizer.ROW_TRADE) {
                b.key = row.Id;
                trades.add(b);
            } else {
                // The same code, fund and date sent twice: the later row (in file order) is the balance.
                b.key = balanceKey(row);
                balances.put(b.key, b);
                aumRows.add(row);
            }
        }
        Datetime now = System.now();
        changes.addAll(bookTrades(trades, now));
        changes.addAll(bookBalances(aumRows, balances, now));
        result.trades = trades.size();
        result.balances = balances.size();
        SystemWriter.updateAll(changes);
    }

    private static List<Import_Staging_Row__c> bookTrades(List<Booking> bookings, Datetime now) {
        List<Import_Staging_Row__c> changes = new List<Import_Staging_Row__c>();
        if (bookings.isEmpty()) {
            return changes;
        }
        Set<String> keys = new Set<String>();
        for (Booking b : bookings) {
            keys.add(b.key);
        }
        // A trade already booked from a row (a load that saved the trade but not the row cannot happen, as each chunk
        // saves all or nothing, but the key makes sure) is updated and its allocations replaced, never doubled.
        Map<String, Id> existing = new Map<String, Id>();
        for (Trade__c t : [SELECT Id, Load_Key__c FROM Trade__c WHERE Load_Key__c IN :keys WITH USER_MODE]) {
            existing.put(t.Load_Key__c, t.Id);
        }
        SystemWriter.deleteAll([SELECT Id FROM Trade_Allocation__c WHERE Trade__c IN :existing.values() WITH USER_MODE]);
        List<Trade__c> inserts = new List<Trade__c>();
        List<Trade__c> updates = new List<Trade__c>();
        List<Trade__c> ordered = new List<Trade__c>();
        for (Booking b : bookings) {
            Import_Staging_Row__c row = b.row;
            Trade__c t = new Trade__c(
                Id = existing.get(b.key),
                Rep_Code__c = row.Matched_Rep_Code__c,
                Fund__c = row.Matched_Fund__c,
                Trade_Date__c = row.Trade_Date__c,
                Transaction_Type__c = row.Transaction_Type__c,
                Amount__c = row.Amount__c,
                Source_Row__c = row.Id,
                Load_Key__c = b.key
            );
            if (t.Id == null) {
                inserts.add(t);
            } else {
                updates.add(t);
            }
            ordered.add(t);
        }
        SystemWriter.insertAll(inserts);
        SystemWriter.updateAll(updates);
        List<Trade_Allocation__c> allocations = new List<Trade_Allocation__c>();
        for (Integer i = 0; i < bookings.size(); i++) {
            Booking b = bookings[i];
            Trade__c t = ordered[i];
            for (TradeAllocator.Share s : TradeAllocator.split(signed(b.row), b.shares)) {
                allocations.add(
                    new Trade_Allocation__c(Trade__c = t.Id, Advisor__c = s.advisorId, Allocation_Percent__c = s.percent, Allocated_Amount__c = s.amount)
                );
            }
            changes.add(new Import_Staging_Row__c(Id = b.row.Id, Loaded_At__c = now, Loaded_Trade__c = t.Id));
        }
        SystemWriter.insertAll(allocations);
        return changes;
    }

    private static List<Import_Staging_Row__c> bookBalances(List<Import_Staging_Row__c> rows, Map<String, Booking> bookings, Datetime now) {
        List<Import_Staging_Row__c> changes = new List<Import_Staging_Row__c>();
        if (bookings.isEmpty()) {
            return changes;
        }
        Map<String, Id> existing = new Map<String, Id>();
        for (AUM_Balance__c b : [SELECT Id, Balance_Key__c FROM AUM_Balance__c WHERE Balance_Key__c IN :bookings.keySet() WITH USER_MODE]) {
            existing.put(b.Balance_Key__c, b.Id);
        }
        // A balance sent again replaces the earlier figure and its split.
        SystemWriter.deleteAll([SELECT Id FROM AUM_Allocation__c WHERE AUM_Balance__c IN :existing.values() WITH USER_MODE]);
        List<AUM_Balance__c> inserts = new List<AUM_Balance__c>();
        List<AUM_Balance__c> updates = new List<AUM_Balance__c>();
        Map<String, AUM_Balance__c> byKey = new Map<String, AUM_Balance__c>();
        for (Booking b : bookings.values()) {
            Import_Staging_Row__c row = b.row;
            AUM_Balance__c bal = new AUM_Balance__c(
                Id = existing.get(b.key),
                Rep_Code__c = row.Matched_Rep_Code__c,
                Fund__c = row.Matched_Fund__c,
                As_Of_Date__c = row.Trade_Date__c,
                Balance__c = row.Amount__c,
                Balance_Key__c = b.key,
                Source_Row__c = row.Id
            );
            if (bal.Id == null) {
                inserts.add(bal);
            } else {
                updates.add(bal);
            }
            byKey.put(b.key, bal);
        }
        SystemWriter.insertAll(inserts);
        SystemWriter.updateAll(updates);
        List<AUM_Allocation__c> allocations = new List<AUM_Allocation__c>();
        for (Booking b : bookings.values()) {
            Id balanceId = byKey.get(b.key).Id;
            for (TradeAllocator.Share s : TradeAllocator.split(b.row.Amount__c, b.shares)) {
                allocations.add(
                    new AUM_Allocation__c(
                        AUM_Balance__c = balanceId,
                        Advisor__c = s.advisorId,
                        Allocation_Percent__c = s.percent,
                        Allocated_Balance__c = s.amount
                    )
                );
            }
        }
        SystemWriter.insertAll(allocations);
        // Every booked AUM row points to its balance, including an earlier row a later one in the file replaced.
        for (Import_Staging_Row__c row : rows) {
            changes.add(new Import_Staging_Row__c(Id = row.Id, Loaded_At__c = now, Loaded_AUM_Balance__c = byKey.get(balanceKey(row)).Id));
        }
        return changes;
    }

    // ================================================================== credit

    /** The open assignments of the rows' codes, largest share first. */
    private static Map<Id, List<Rep_Code_Assignment__c>> assignments(List<Import_Staging_Row__c> rows) {
        Set<Id> codeIds = new Set<Id>();
        for (Import_Staging_Row__c row : rows) {
            if (row.Matched_Rep_Code__c != null) {
                codeIds.add(row.Matched_Rep_Code__c);
            }
        }
        Map<Id, List<Rep_Code_Assignment__c>> result = new Map<Id, List<Rep_Code_Assignment__c>>();
        for (Rep_Code_Assignment__c a : [
            SELECT Id, Rep_Code__c, Advisor__c, Allocation_Percent__c, Effective_Start_Date__c, Effective_End_Date__c
            FROM Rep_Code_Assignment__c
            WHERE Rep_Code__c IN :codeIds
            WITH USER_MODE
            ORDER BY Allocation_Percent__c DESC, Effective_Start_Date__c, Id
        ]) {
            if (!result.containsKey(a.Rep_Code__c)) {
                result.put(a.Rep_Code__c, new List<Rep_Code_Assignment__c>());
            }
            result.get(a.Rep_Code__c).add(a);
        }
        return result;
    }

    /**
     * Who is credited for a row, and with what share: the Credited Advisor 100%, else the shares active on the row's
     * date (the same test matching uses). Null when a team's active shares do not total 100%.
     */
    @TestVisible
    private static List<TradeAllocator.Share> sharesOn(Import_Staging_Row__c row, List<Rep_Code_Assignment__c> onCode) {
        if (row.Credited_Advisor__c != null) {
            return new List<TradeAllocator.Share>{ new TradeAllocator.Share(row.Credited_Advisor__c, 100) };
        }
        List<TradeAllocator.Share> shares = new List<TradeAllocator.Share>();
        Decimal total = 0;
        Date d = row.Trade_Date__c;
        for (Rep_Code_Assignment__c a : onCode == null ? new List<Rep_Code_Assignment__c>() : onCode) {
            if (a.Effective_Start_Date__c <= d && (a.Effective_End_Date__c == null || a.Effective_End_Date__c >= d)) {
                Decimal pct = a.Allocation_Percent__c == null ? 0 : a.Allocation_Percent__c;
                if (pct <= 0) {
                    return null;
                }
                shares.add(new TradeAllocator.Share(a.Advisor__c, pct));
                total += pct;
            }
        }
        return shares.isEmpty() || total != 100 ? null : shares;
    }

    /** Signed amount, as on the Trade: redemptions negative. */
    @TestVisible
    private static Decimal signed(Import_Staging_Row__c row) {
        return row.Transaction_Type__c == 'Redemption' ? -row.Amount__c : row.Amount__c;
    }

    /** Code, fund (or ALL) and date: one AUM Balance per key. */
    @TestVisible
    private static String balanceKey(Import_Staging_Row__c row) {
        return row.Matched_Rep_Code__c +
            '|' +
            (row.Matched_Fund__c == null ? ALL_FUNDS : (String) row.Matched_Fund__c) +
            '|' +
            String.valueOf(row.Trade_Date__c);
    }

    /** A row that cannot load as matched goes back to matching, with the reason first in its notes. */
    private static Import_Staging_Row__c sendBack(Import_Staging_Row__c row, String problem) {
        String note = 'Not loaded on ' + System.today().format() + ': ' + problem + '. Sent back to matching.';
        return new Import_Staging_Row__c(
            Id = row.Id,
            Match_Status__c = TradeMatcher.PENDING,
            Match_Notes__c = (String.isBlank(row.Match_Notes__c) ? note : note + '\n' + row.Match_Notes__c).abbreviate(5000)
        );
    }

    // ================================================================== the file

    /**
     * After the last chunk: Completed when no row is waiting and none is left to load, else back to Pending Review.
     * Rows sent back to matching are matched again straight away when a job slot is free (else by the sweeper).
     */
    private static void finish(Id batchId) {
        Integer waiting = [SELECT COUNT() FROM Import_Staging_Row__c WHERE Import_Batch__c = :batchId AND Match_Status__c IN :WAITING WITH USER_MODE];
        Boolean done = waiting == 0 && loadableCount(batchId) == 0;
        SystemWriter.updateOne(
            new Import_Batch__c(
                Id = batchId,
                Status__c = done ? STATUS_COMPLETED : TradeMatcher.STATUS_PENDING_REVIEW,
                Loaded_Row_Count__c = loadedCount(batchId)
            )
        );
        TradeViewNotifier.fileSettled(new Set<Id>{ batchId }, TradeViewNotifier.MOMENT_LOADED);
        Boolean pending =
            [SELECT COUNT() FROM Import_Staging_Row__c WHERE Import_Batch__c = :batchId AND Match_Status__c = :TradeMatcher.PENDING WITH USER_MODE] > 0;
        if (pending && !Test.isRunningTest() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new TradeMatcher(new Set<Id>{ batchId }));
        }
    }

    private static Integer loadedCount(Id batchId) {
        return [SELECT COUNT() FROM Import_Staging_Row__c WHERE Import_Batch__c = :batchId AND Loaded_At__c != NULL WITH USER_MODE];
    }

    // ================================================================== protection

    /**
     * Before update: a loaded row is booked, so its match result and load stamps cannot change any more (only a
     * data fix can). Stops a later decision or re-match from crediting a booked trade twice.
     */
    public static void protectLoaded(List<Import_Staging_Row__c> rows, Map<Id, Import_Staging_Row__c> previous) {
        List<Import_Staging_Row__c> changed = new List<Import_Staging_Row__c>();
        for (Import_Staging_Row__c row : rows) {
            Import_Staging_Row__c before = previous.get(row.Id);
            if (
                before.Loaded_At__c != null &&
                (row.Match_Status__c != before.Match_Status__c ||
                row.Loaded_At__c != before.Loaded_At__c ||
                row.Loaded_Trade__c != before.Loaded_Trade__c ||
                row.Loaded_AUM_Balance__c != before.Loaded_AUM_Balance__c ||
                row.Credited_Advisor__c != before.Credited_Advisor__c ||
                row.Matched_Rep_Code__c != before.Matched_Rep_Code__c)
            ) {
                changed.add(row);
            }
        }
        if (changed.isEmpty() || SystemFieldGuard.mayFixData()) {
            return;
        }
        for (Import_Staging_Row__c row : changed) {
            row.addError('This row is already loaded, so its match can no longer change. Correct the Trade or AUM Balance instead.');
        }
    }
}
