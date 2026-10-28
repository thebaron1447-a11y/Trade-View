# Phase 1: Data model and seed data

Extract this zip into `C:\dev\trade-import-demo` (merge with the existing `force-app` folder), then run from that folder:

```powershell
sf project deploy start --source-dir force-app --target-org tradeDemo --dry-run
sf project deploy start --source-dir force-app --target-org tradeDemo
sf org assign permset --name Trade_Import_Admin --target-org tradeDemo
sf data import tree --plan data/seed-plan.json --target-org tradeDemo
```

No tabs yet (they come with the app in phase 4). View records at:
`/lightning/o/Rep_Code__c/list`, `/lightning/o/Rep_Code_Assignment__c/list`, `/lightning/o/Firm_Alias__c/list`, `/lightning/o/Fund_Alias__c/list`

## Objects

| Object | Purpose |
|---|---|
| Rep_Code__c | Dealer code issued by a firm (Account) |
| Rep_Code_Assignment__c | Code to advisor (Contact), with % and effective dates |
| Trade__c | One fund purchase or redemption, under a code |
| Trade_Allocation__c | One advisor's snapshotted share of a trade |
| Firm_Alias__c | Approved firm/branch name variants |
| Fund_Alias__c | Approved fund name variants (Product2) |

## Planted traps in the seed data

| Trap | Where |
|---|---|
| Firm name variants | Barder & Company / Barder and Co / Barder and C. all normalize to `barder` |
| Accents dropped | Lumière vs Lumiere produce different keys; covered by an alias |
| Two firms, one key | Kestrel Capital Inc. and Ltd. both normalize to `kestrel capital`, and both use code 1001 |
| Advisor moved firms | Julia Morales: Northgate 3102 (ended 2024-05-28), then Barder 457 |
| Silent code reassignment | Barder 2210 (Marcus Bell); phase 2 files will show a new advisor on it |
| Dormant code | Northgate 5521, last trade 2025-02-03 |
| Shared code | Lumière 7700 split 60/40 |
| Incomplete split | Northgate 8800 active total is 80% after Sam Whitford left |
| Ambiguous fund | "ETF Wealth World Fund A" is deliberately not aliased |
