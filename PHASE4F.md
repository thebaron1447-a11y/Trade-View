# Phase 4f: one review layout, and code reviews on hold

Dealer Code Review and Data Review used to show their items in two different layouts, and a code review could be
assigned but not put on hold. Both now read the same way (see section 26 of the build log):

- **Header:** what kind of item it is and its status, the root cause as the title, where it came from, and who it is
  assigned to, with Assign to me or Unassign.
- **Hold banner**, when it waits on a firm: *Waiting on [firm] since … · put on hold by …*, with the question.
- **1 · What came in:** a row shows as one table line with the cell that needs a person shaded and labelled (for
  example *Fund · Not recognised*); a code review shows its held rows in the same form.
- **2 · Claude's answer:** confidence, the answer per field and why, and the question for the firm.
- **3 · Your decision:** for a row, the choices filled in from Claude (labelled as such); for a code review, the ways
  to settle it as one pick-one list, with Claude's answer marked and chosen.
- **Action bar**, kept at the bottom of the page: the main action first (its label follows the choice, for example
  *Confirm Tom Reilly*), then Put on hold or Release, then Reject for rows.

Holding a code review moves it to **On Hold** beside on-hold rows and makes its question the code's entry in the firm's
next follow-up email (Email Firms). Its rows stay held, because the code holds them. Settling it from On Hold works as
usual and takes it off hold; Release hold sends it back to Dealer Code Review.

## 1. Validate and deploy (32 test classes, expect 222 tests)

This deploy also carries phase 4c (the cloud pull) if it is not deployed yet.

```powershell
.\scripts\deploy.ps1 -DryRun
.\scripts\deploy.ps1
```

## 2. Try it

Reset first: `.\scripts\reset-demo-full.ps1`, then open Trade Review.

| Try | You should see |
|---|---|
| Data Review → *Global Bond Fd Ser F* (Barder, 2026-10-12 file) | The row as one line with the Fund cell marked *Not recognised*; Claude's answer High; the Fund choice *filled in from Claude* |
| Dealer Code Review → code 5521 | The same layout; *Confirm Tom Reilly still uses code 5521* chosen; the main button reads *Confirm Tom Reilly* |
| Choose another fix | The main button's label changes with it (*Re-match*, *Send to Data Review*, *Credit …*) |
| Code 3390 → Put on hold | The dialog has the question filled in; after saving, 3390 is on the On Hold tab with the *Waiting on Barder* banner, and its question is listed under Email Firms → Barder |
| On Hold → 3390 → Release hold | Back in Dealer Code Review |

## 3. Optional: run the LWC tests on your computer

```powershell
npm run test:unit
```

68 Jest tests should pass.
