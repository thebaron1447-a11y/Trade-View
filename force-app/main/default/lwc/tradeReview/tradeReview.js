import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { encodeDefaultFieldValues } from "lightning/pageReferenceUtils";
import getQueue from "@salesforce/apex/ReviewController.getQueue";
import decideRow from "@salesforce/apex/ReviewController.decideRow";
import setAssignment from "@salesforce/apex/ReviewController.setAssignment";
import activateMapping from "@salesforce/apex/ReviewController.activateMapping";
import uploadFile from "@salesforce/apex/ReviewController.uploadFile";
import holdRow from "@salesforce/apex/ReviewController.holdRow";
import releaseHold from "@salesforce/apex/ReviewController.releaseHold";
import draftFirmEmail from "@salesforce/apex/ReviewController.draftFirmEmail";
import markAsked from "@salesforce/apex/ReviewController.markAsked";
import getIssueRows from "@salesforce/apex/ReviewController.getIssueRows";
import creditCodeReview from "@salesforce/apex/ReviewController.creditCodeReview";
import closeCodeReview from "@salesforce/apex/ReviewController.closeCodeReview";
import loadFile from "@salesforce/apex/ReviewController.loadFile";
import confirmHolder from "@salesforce/apex/ReviewController.confirmHolder";
import pullNow from "@salesforce/apex/ReviewController.pullNow";
import setPullSchedule from "@salesforce/apex/ReviewController.setPullSchedule";
import holdCodeReview from "@salesforce/apex/ReviewController.holdCodeReview";
import releaseCodeReviewHold from "@salesforce/apex/ReviewController.releaseCodeReviewHold";
import { subscribe, unsubscribe, onError } from "lightning/empApi";

// Background work announces itself when it finishes (Trade View Update platform event), and the page refreshes
// then. If the page cannot listen (no streaming), it checks every few seconds instead, for up to three minutes
// after the last action. While listening it still checks now and then, in case an update is missed.
export const CHANNEL = "/event/Trade_View_Update__e";
export const POLL_MS = 5000;
export const SAFETY_POLL_MS = 30000;
export const MAX_POLLS = 36;
export const UPDATE_DEBOUNCE_MS = 750;
export const MAX_UPLOAD_BYTES = 1024 * 1024;
// A question asked this long ago without an answer gets a reminder label.
export const NUDGE_DAYS = 3;
const DAY_MS = 24 * 60 * 60 * 1000;
const ACTION_LABELS = {
  Accept: "Recommended: accept.",
  Reject: "Recommended: reject.",
  Hold: "Recommended: put on hold and ask the firm."
};
// The confidence badge in the detail pane (soft colours that differ in lightness, with the level written out).
const CONFIDENCE_BADGE = {
  High: "tv-chip conf-high",
  Medium: "tv-chip conf-medium",
  Low: "tv-chip conf-low"
};
// Which cell of a row each match flag is about, and the short note shown under it.
const CELL_FLAGS = {
  FIRM_MISSING: ["firm", "Missing"],
  FIRM_UNRESOLVED: ["firm", "Not recognised"],
  FIRM_AMBIGUOUS: ["firm", "Fits more than one"],
  FUND_UNRESOLVED: ["fund", "Not recognised"],
  FUND_AMBIGUOUS: ["fund", "Fits more than one"],
  UNKNOWN_CODE: ["code", "Not set up"],
  CODE_ENDED: ["code", "Ended"],
  DATE_BEFORE_CODE_START: ["date", "Before the code started"],
  DORMANT_CODE_NO_NAME: ["code", "Dormant"],
  DORMANT_CODE_REACTIVATED: ["code", "Dormant"],
  ALLOCATION_INCOMPLETE: ["code", "Shares under 100%"],
  ROSTER_NEW_CODE: ["code", "New code"],
  ROSTER_NEW_HOLDER: ["advisor", "New holder"],
  REASSIGNMENT_SUSPECTED: ["advisor", "Not the holder"],
  TEAM_CHANGE_SUSPECTED: ["advisor", "Not on the team"],
  NEW_ADVISOR: ["advisor", "Not in Salesforce"],
  ADVISOR_AMBIGUOUS: ["advisor", "Fits more than one"]
};
// What a code review's reason says about the code cell of each held row.
const REASON_CODE_NOTES = {
  "Unknown Code": "Not set up",
  "Code Ended": "Ended",
  "Code Dormant": "Dormant",
  "Allocation Incomplete": "Shares under 100%"
};
// The ways to settle a code review, in the order offered.
export const FIX_CONFIRM = "confirm";
export const FIX_CREDIT = "credit";
export const FIX_REMATCH = "rematch";
export const FIX_SEND = "send";
const OTHER_FIRM = "__other__";
const SCOPES = [
  { label: "All", value: "all" },
  { label: "Mine", value: "mine" },
  { label: "Unassigned", value: "unassigned" }
];
const CONFIDENCE_CLASS = {
  High: "slds-theme_success",
  Medium: "slds-theme_warning",
  Low: "slds-theme_error"
};

/** The message to show for an Apex or JavaScript error. */
export function errorText(error) {
  if (!error) {
    return "Something went wrong.";
  }
  if (Array.isArray(error.body)) {
    return error.body.map((e) => e.message).join(" ");
  }
  if (error.body && typeof error.body.message === "string") {
    return error.body.message;
  }
  return error.message || "Something went wrong.";
}

function money(value) {
  if (value === null || value === undefined) {
    return "";
  }
  return (
    "$" +
    Number(value).toLocaleString("en-CA", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    })
  );
}

function shortDate(value) {
  if (!value) {
    return "";
  }
  return new Date(value).toLocaleDateString("en-CA", {
    month: "short",
    day: "numeric"
  });
}

/** "Accepted 37 rows. …" for a group; the single-row wording otherwise. Apex returns how many rows changed. */
/** A date-only value ("2026-09-15") as "Sep 15", read as a calendar date so no time zone moves it a day. */
export function dayText(value) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
  if (!m) {
    return "";
  }
  return new Date(
    Number(m[1]),
    Number(m[2]) - 1,
    Number(m[3])
  ).toLocaleDateString("en-CA", {
    month: "short",
    day: "numeric",
    year: "numeric"
  });
}

/**
 * How a waiting roster change affects a code review, from the rule the server applies: it holds rows back only when
 * it can be approved, and only the rows it covers. All, some, or none (then it is shown for information).
 */
export function rosterState(f) {
  const held = f.heldRowCount || 0;
  const covered = f.rosterApprovable ? f.rosterCovered || 0 : 0;
  return {
    rosterFirst: !!f.rosterRowId && covered > 0 && covered >= held,
    rosterPartial: !!f.rosterRowId && covered > 0 && covered < held,
    rosterInfo: !!f.rosterRowId && covered === 0,
    workableCount: held - covered,
    rosterDateText: dayText(f.rosterDate)
  };
}

/** "1 row", "3 rows". */
export function plural(count, noun) {
  const n = Number(count) || 0;
  return `${n} ${n === 1 ? noun : noun + "s"}`;
}

/** What a code review holds, by kind: "1 trade ($1,200,000.00) and 1 AUM balance held". */
export function heldText(f) {
  const trades = f.tradeCount || 0;
  const aum = f.aumCount || 0;
  const parts = [];
  if (trades) {
    parts.push(`${plural(trades, "trade")} (${money(f.heldAmount)})`);
  }
  if (aum) {
    parts.push(plural(aum, "AUM balance"));
  }
  const other = (f.heldRowCount || 0) - trades - aum;
  if (other > 0) {
    parts.push(plural(other, "other row"));
  }
  return parts.length
    ? `${parts.join(" and ")} held`
    : `${plural(f.heldRowCount, "row")} held`;
}

/** Claude's advisor for a code review, pre-chosen only when it is one of the people the reviewer can credit. */
export function claudeCredit(f) {
  return f &&
    f.aiAdvisorId &&
    (f.creditOptions || []).some((o) => o.value === f.aiAdvisorId)
    ? f.aiAdvisorId
    : undefined;
}

/**
 * The fix pre-chosen for a code review: Claude's when it points to one (its advisor holds a dormant code, or can be
 * credited), otherwise the first one available. options are fixOptions() entries.
 */
export function defaultFix(f, options) {
  const open = (options || []).filter((o) => !o.disabled);
  const claude = open.find((o) => o.fromClaude);
  if (claude) {
    return claude.value;
  }
  return open.length ? open[0].value : undefined;
}

export function bulkMessage(count, one, many) {
  const n = Number(count) || 1;
  return n > 1 ? many.replace("{n}", n) : one;
}

/** "Asked Oct 20", plus a reminder once NUDGE_DAYS have passed without an answer. */
export function askedText(askedAt, now = Date.now()) {
  if (!askedAt) {
    return "";
  }
  const days = Math.floor((now - new Date(askedAt).getTime()) / DAY_MS);
  const asked = `Asked ${shortDate(askedAt)}`;
  return days >= NUDGE_DAYS
    ? `${asked} · no answer after ${days} days, send a reminder`
    : asked;
}

/** "Waiting on Northgate since Nov 3 · put on hold by Greg Baronian". */
export function holdTitle(firmName, heldSince, heldByName) {
  const since = heldSince ? ` since ${shortDate(heldSince)}` : "";
  const by = heldByName ? ` · put on hold by ${heldByName}` : "";
  return `Waiting on ${firmName || "the firm"}${since}${by}`;
}

// How often a cloud folder is checked (Cloud Source Pull Frequency).
export const PULL_FREQUENCIES = [
  "Manual only",
  "Every 15 minutes",
  "Hourly",
  "Every 4 hours",
  "Daily"
].map((v) => ({ label: v, value: v }));
export const PULL_HOURS = Array.from({ length: 24 }, (_, h) => ({
  label: `${h % 12 === 0 ? 12 : h % 12}:00 ${h < 12 ? "am" : "pm"}`,
  value: String(h)
}));

/** "Nov 3, 9:40 a.m." in the viewer's time zone. */
export function whenText(value) {
  if (!value) {
    return "";
  }
  return new Date(value).toLocaleString("en-CA", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

/** What a cloud folder is doing, in one line. */
export function pullText(s) {
  if (!s.active) {
    return "Not active. An admin turns it on in its Cloud Source record.";
  }
  if (s.lastStatus === "Pulling") {
    return "Checking for new files now…";
  }
  const last = s.lastPullAt
    ? `Last checked ${whenText(s.lastPullAt)}${s.lastStatus === "Failed" ? " (failed)" : ""}: ${s.lastMessage || ""}`
    : "Not checked yet.";
  const next = s.nextPullAt
    ? ` Next check ${whenText(s.nextPullAt)}.`
    : " Checked only when you click Pull now.";
  return last + next;
}

/** The base64 part of a data URL (data:text/csv;base64,XXXX). */
export function base64Of(dataUrl) {
  const text = String(dataUrl || "");
  const comma = text.indexOf(",");
  return comma >= 0 ? text.substring(comma + 1) : "";
}

export default class TradeReview extends NavigationMixin(LightningElement) {
  scope = "all";
  activeTab = "codes";
  queue;
  loading = true;
  busy = false;
  loadError;
  selectedKey;

  // Decision choices for the selected row, prefilled with Claude's suggestion.
  firmChoice;
  fundChoice;
  advisorChoice;
  creditChoice;
  // How the selected code review is to be settled (FIX_*), pre-chosen from Claude's answer.
  fixChoice;
  remember = false;

  // Upload dialog.
  showUpload = false;
  uploadFirm;
  uploadOtherFirm = "";
  uploadFileRef;
  uploadError;
  uploading = false;

  // Put on hold dialog.
  showHold = false;
  holdText = "";

  // The rows sharing the selected row's issue, loaded when it is opened.
  issueRows;
  issueRowsFor;

  // After a follow-up email is opened: which questions to mark as asked once it is sent.
  pendingAsk;

  pollTimer;
  polls = 0;
  // Listening for background updates.
  subscription;
  live = false;
  updateTimer;

  scopeOptions = SCOPES;

  connectedCallback() {
    this.load();
    this.listen();
  }

  disconnectedCallback() {
    this.stopPolling();
    if (this.updateTimer) {
      clearTimeout(this.updateTimer);
      this.updateTimer = undefined;
    }
    if (this.subscription) {
      unsubscribe(this.subscription).catch(() => {});
      this.subscription = undefined;
    }
  }

  /** Listens for background work finishing; falls back to checking every few seconds if it cannot. */
  async listen() {
    try {
      onError(() => this.goOffline());
      this.subscription = await subscribe(CHANNEL, -1, () =>
        this.handleUpdate()
      );
      this.live = true;
      this.restartPolling();
    } catch {
      // No streaming here (for example a community page): fall back to checking every few seconds.
      this.goOffline();
    }
  }

  goOffline() {
    this.live = false;
    this.restartPolling();
  }

  /** One refresh for a burst of updates (a load sends one per chunk). */
  handleUpdate() {
    if (this.updateTimer) {
      return;
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.updateTimer = setTimeout(() => {
      this.updateTimer = undefined;
      this.polls = 0;
      this.load();
    }, UPDATE_DEBOUNCE_MS);
  }

  restartPolling() {
    this.stopPolling();
    this.managePolling();
  }

  // ------------------------------------------------------------------ loading and refreshing

  async load() {
    try {
      this.queue = await getQueue({ scope: this.scope });
      this.loadError = undefined;
      this.keepSelection();
      this.managePolling();
    } catch (e) {
      this.loadError = errorText(e);
      this.stopPolling();
    } finally {
      this.loading = false;
    }
  }

  /** Called after every action: refresh now and keep refreshing while background work runs. */
  refreshAfterAction() {
    this.polls = 0;
    return this.load();
  }

  managePolling() {
    const working =
      this.queue && this.queue.inFlight > 0 && this.polls < MAX_POLLS;
    if (working && !this.pollTimer) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this.pollTimer = setInterval(
        () => {
          this.polls += 1;
          this.load();
        },
        this.live ? SAFETY_POLL_MS : POLL_MS
      );
    } else if (!working) {
      this.stopPolling();
    }
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
  }

  handleRefresh() {
    this.refreshAfterAction();
  }

  handleScopeChange(event) {
    this.scope = event.detail.value;
    this.selectedKey = undefined;
    this.loading = true;
    this.refreshAfterAction();
  }

  handleTabActive(event) {
    this.activeTab = event.target.value;
    this.keepSelection();
  }

  /** Keeps the selected item if it is still on the open tab; otherwise selects that tab's first item. */
  keepSelection() {
    // Only items on the open tab can stay selected, so switching tabs always shows that tab's item.
    const byTab = {
      codes: this.codeTableItems,
      rows: this.decisionTableItems,
      hold: this.holdTableItems,
      firms: this.firmTableItems,
      mappings: this.mappingTableItems
    };
    const items = byTab[this.activeTab] || [];
    if (this.selectedKey && items.some((i) => i.key === this.selectedKey)) {
      this.fillFromClaude();
      return;
    }
    this.select(items.length ? items[0].key : undefined);
  }

  select(key) {
    this.selectedKey = key;
    const row = this.selectedRow;
    this.firmChoice = row ? row.aiFirmId || undefined : undefined;
    this.fundChoice = row ? row.aiFundId || undefined : undefined;
    this.advisorChoice = row ? row.aiAdvisorId || undefined : undefined;
    this.creditChoice = claudeCredit(row ? undefined : this.selectedFollowUp);
    this.fixChoice = defaultFix(this.selectedFollowUp, this.fixOptions);
    this.remember = false;
    this.loadIssueRows(row);
  }

  /** Lists the rows a group decision will change (once per row opened). */
  async loadIssueRows(row) {
    if (!row || !(row.groupCount > 1)) {
      this.issueRows = undefined;
      this.issueRowsFor = undefined;
      return;
    }
    if (this.issueRowsFor === row.id) {
      return;
    }
    this.issueRowsFor = row.id;
    this.issueRows = undefined;
    try {
      const rows = await getIssueRows({ rowId: row.id });
      if (this.issueRowsFor === row.id) {
        this.issueRows = (rows || []).map((r) => ({
          ...r,
          key: r.id,
          where: `${r.fileName || "File"} · row ${r.rowNumber}`,
          amountText: money(r.amount)
        }));
      }
    } catch (e) {
      this.issueRows = [];
      this.toast("error", errorText(e));
    }
  }

  get selectedIsGroup() {
    const r = this.selectedRow;
    return !!(r && r.groupCount > 1);
  }

  get groupSummary() {
    const r = this.selectedRow;
    if (!r || !(r.groupCount > 1)) {
      return "";
    }
    const files =
      r.groupFileCount === 1 ? "1 file" : `${r.groupFileCount} files`;
    return `This issue affects ${r.groupCount} rows (${money(r.groupAmount)}) across ${files}. Your decision applies to all of them.`;
  }

  get issueRowsNote() {
    const r = this.selectedRow;
    const shown = (this.issueRows || []).length;
    return r && shown && shown < r.groupCount
      ? `Showing the first ${shown} of ${r.groupCount} rows.`
      : "";
  }

  /** "Accept" for one row, "Accept all 37" for a group. */
  groupLabel(base) {
    const r = this.selectedRow;
    return r && r.groupCount > 1 ? `${base} all ${r.groupCount}` : base;
  }

  get fileHeading() {
    const r = this.selectedRow;
    return r && r.groupCount > 1
      ? `From the file (first of ${r.groupCount} rows)`
      : "From the file";
  }

  get holdGroupText() {
    const r = this.selectedRow;
    return r && r.groupCount > 1
      ? `All ${r.groupCount} rows with this issue go on hold together, as one question for the firm.`
      : "";
  }

  get rejectLabel() {
    return this.groupLabel("Reject");
  }

  get holdButtonLabel() {
    const r = this.selectedRow;
    return r && r.groupCount > 1
      ? `Put all ${r.groupCount} on hold`
      : "Put on hold";
  }

  get releaseLabel() {
    return this.selectedRow ? this.groupLabel("Release") : "Release hold";
  }

  /** When Claude's suggestion arrives after the row was opened, fill in any choice the reviewer has not made. */
  fillFromClaude() {
    const row = this.selectedRow;
    if (!row) {
      this.creditChoice =
        this.creditChoice || claudeCredit(this.selectedFollowUp);
      // Keep the reviewer's pick while it is still available (a refresh can lock options).
      const options = this.fixOptions;
      if (!options.some((o) => o.value === this.fixChoice && !o.disabled)) {
        this.fixChoice = defaultFix(this.selectedFollowUp, options);
      }
      return;
    }
    this.firmChoice = this.firmChoice || row.aiFirmId || undefined;
    this.fundChoice = this.fundChoice || row.aiFundId || undefined;
    this.advisorChoice = this.advisorChoice || row.aiAdvisorId || undefined;
  }

  /** From the queue table: detail.key is the item clicked. */
  handleSelect(event) {
    this.select(event.detail.key);
  }

  // ------------------------------------------------------------------ queue views

  /** Every row waiting for a person (open and on hold), with what the detail pane needs. */
  get allRowViews() {
    const open = (this.queue && this.queue.rows) || [];
    const held = (this.queue && this.queue.holdRows) || [];
    return [...open, ...held].map((r) => {
      const notes = r.noteLines && r.noteLines.length ? r.noteLines : null;
      return {
        ...r,
        key: "row:" + r.id,
        title: r.headline || `${r.sourceFirm || "File"} · row ${r.rowNumber}`,
        subtitle: r.origin || r.rowType,
        whyLines: notes || r.reasons || [],
        hasConfidence: !!r.aiConfidence,
        confidenceClass: CONFIDENCE_CLASS[r.aiConfidence] || "",
        assignedLabel: this.assignedLabel(r),
        actionLabel: ACTION_LABELS[r.aiAction] || "",
        heldSinceText: shortDate(r.heldSince),
        holdTitle: holdTitle(
          r.followUpFirmName || r.sourceFirm,
          r.heldSince,
          r.heldByName
        ),
        askedLabel: askedText(r.askedAt),
        hasPlan: !!(r.isRoster && r.approvalPlan && r.approvalPlan.length),
        settlesKey: r.settlesFollowUpId ? "fu:" + r.settlesFollowUpId : "",
        settlesText: r.settlesFollowUpId
          ? `Approving this also closes the code ${r.settlesCode} review and re-matches its ${plural(r.settlesRowCount, "held row")}${r.settlesAmount ? ` (${money(r.settlesAmount)} in trades)` : ""}`
          : "",
        planLines: (r.approvalPlan || []).map((line, i) => ({
          key: String(i),
          text: line
        }))
      };
    });
  }

  get followUpViews() {
    const items = (this.queue && this.queue.followUps) || [];
    return items.map((f) => ({
      ...f,
      key: "fu:" + f.id,
      title: `Code ${f.repCode} · ${f.firmName || "unknown firm"}`,
      subtitle: heldText(f),
      issueText: f.heldIssue || f.reason,
      heldSummary: `${plural(f.heldRowCount, "row")} · ${money(f.heldAmount)}`,
      canCredit: !!(f.advisorOptions && f.advisorOptions.length),
      ...rosterState(f),
      rosterKey: f.rosterRowId ? "row:" + f.rosterRowId : "",
      creditOptions: f.advisorOptions || [],
      hasConfidence: !!f.aiConfidence,
      confidenceClass: CONFIDENCE_CLASS[f.aiConfidence] || "",
      assignedLabel: this.assignedLabel(f),
      askedLabel: askedText(f.askedAt),
      holdTitle: holdTitle(f.firmName, f.heldSince, f.heldByName)
    }));
  }

  /** Code reviews still being worked (on hold ones are on the On Hold tab). */
  get openFollowUpViews() {
    return this.followUpViews.filter((f) => !f.onHold);
  }

  get heldFollowUpViews() {
    return this.followUpViews.filter((f) => f.onHold);
  }

  /** Firms with questions waiting for their answer, one email each. */
  get firmFollowUpViews() {
    const firms = (this.queue && this.queue.firmFollowUps) || [];
    return firms.map((f) => {
      const questions =
        f.questionCount === 1 ? "1 question" : `${f.questionCount} questions`;
      let status;
      if (!f.contactEmail) {
        status = "No Operations Contact with an email on the firm";
      } else if (f.notAskedCount) {
        status = `${f.notAskedCount} not asked yet`;
      } else {
        status = askedText(f.lastAskedAt);
      }
      return {
        ...f,
        key: "firm:" + f.firmId,
        questionsText: questions,
        status,
        noContact: !f.contactEmail,
        buttonLabel: f.notAskedCount ? "Email the firm" : "Send a reminder",
        questionViews: (f.questions || []).map((q, i) => ({
          ...q,
          key: String(i),
          askedLabel: askedText(q.askedAt) || "Not asked yet"
        }))
      };
    });
  }

  get mappingViews() {
    const items = (this.queue && this.queue.mappings) || [];
    return items.map((m) => ({
      ...m,
      key: "map:" + m.batchId,
      title: `${m.sourceFirm} · ${m.fileName || m.batchName}`,
      subtitle: m.profileId
        ? "Claude proposed a mapping"
        : "Waiting for a mapping"
    }));
  }

  get fileViews() {
    const items = (this.queue && this.queue.recentFiles) || [];
    return items.map((f) => ({
      ...f,
      summary:
        f.rowCount === null || f.rowCount === undefined
          ? f.status
          : `${f.status} · ${f.rowCount} rows: ${f.matchedCount || 0} matched, ${f.reviewCount || 0} to review, ${f.heldCount || 0} held, ${f.errorCount || 0} invalid` +
            (f.loadedCount ? `, ${f.loadedCount} loaded` : ""),
      loadLabel: `Load ${plural(f.loadableCount, "matched row")}`,
      loadNote:
        f.canLoad && (f.reviewCount || f.heldCount)
          ? "Rows in review or on hold load later, once they are decided."
          : ""
    }));
  }

  /** Load file: books the file's matched rows as trades and AUM balances, in the background. */
  async handleLoadFile(event) {
    const batchId = event.currentTarget.dataset.id;
    await this.run(
      () => loadFile({ batchId }),
      (n) =>
        `Loading ${plural(n, "row")}. Trades and AUM balances appear when it finishes.`
    );
  }

  // Every tab shows the same table: the item, its issue type (with Claude's view) and an amount or count.

  /** A row as a table line. */
  rowLine(r, note) {
    const badges = [];
    if (r.aiConfidence) {
      badges.push({
        key: "c",
        label: `Claude: ${r.aiConfidence}`,
        cls: "slds-badge " + (CONFIDENCE_CLASS[r.aiConfidence] || "")
      });
    }
    if (r.aiAction) {
      badges.push({ key: "a", label: r.aiAction, cls: "slds-badge" });
    }
    return {
      key: r.key,
      title: r.title,
      subtitle:
        r.groupCount > 1
          ? `${r.sourceFirm || "File"} · ${r.groupFileCount === 1 ? "1 file" : `${r.groupFileCount} files`}`
          : r.subtitle,
      note: note || (r.assignedLabel ? `Assigned: ${r.assignedLabel}` : ""),
      issueType: r.issueType || (r.reasons && r.reasons[0]) || r.rowType,
      issueDetail: r.issueCount > 1 ? `+${r.issueCount - 1} more` : "",
      badges,
      lastText: r.isRoster
        ? "Roster"
        : r.groupCount > 1
          ? `${r.groupCount} rows · ${money(r.groupAmount)}`
          : r.amount === null || r.amount === undefined
            ? ""
            : money(r.amount)
    };
  }

  /** Starts a group (a header line) at each item whose group differs from the one before. */
  grouped(lines, groupOf) {
    let last;
    return lines.map((line) => {
      const group = groupOf(line);
      const out = group !== last ? { ...line, groupLabel: group } : line;
      last = group;
      return out;
    });
  }

  get codeRowViews() {
    return this.allRowViews.filter((r) => !r.onHold && r.isCodeIssue);
  }

  get decisionRowViews() {
    return this.allRowViews.filter((r) => !r.onHold && !r.isCodeIssue);
  }

  get holdViews() {
    return this.allRowViews.filter((r) => r.onHold);
  }

  /** Dealer Code Review: codes to fix (with their held trades), then roster and other code decisions. */
  get codeTableItems() {
    const codes = this.openFollowUpViews.map((f) => this.codeLine(f));
    const rows = this.codeRowViews.map((r) => ({
      ...this.rowLine(
        r,
        r.settlesCode ? `Settles the code ${r.settlesCode} review` : ""
      ),
      group: "Roster and code decisions"
    }));
    return this.grouped([...codes, ...rows], (l) => l.group);
  }

  /** A code review as a table line. */
  codeLine(f) {
    return {
      key: f.key,
      title: `Code ${f.repCode}`,
      subtitle: f.firmName || "Unknown firm",
      note:
        f.askedLabel || (f.assignedLabel ? `Assigned: ${f.assignedLabel}` : ""),
      issueType: f.reason,
      issueDetail: f.rosterFirst
        ? "Roster change first"
        : f.rosterPartial
          ? `Roster change first for ${f.rosterCovered} of ${f.heldRowCount}`
          : "",
      badges: f.aiConfidence
        ? [
            {
              key: "c",
              label: `Claude: ${f.aiConfidence}`,
              cls: "slds-badge " + (CONFIDENCE_CLASS[f.aiConfidence] || "")
            }
          ]
        : [],
      lastText: f.heldSummary,
      group: "Codes to fix"
    };
  }

  /** Data Review: everything else (firm, fund and other data questions), grouped by file. */
  get decisionTableItems() {
    return this.grouped(
      this.decisionRowViews.map((r) => ({
        ...this.rowLine(r),
        group: `${r.sourceFirm || "File"} · ${r.fileName || ""}`
      })),
      (l) => l.group
    );
  }

  /** On Hold: code reviews and rows waiting for a firm's answer, together. */
  get holdTableItems() {
    const codes = this.heldFollowUpViews.map((f) => ({
      ...this.codeLine(f),
      note: f.askedLabel,
      issueDetail: f.holdReason,
      group: undefined
    }));
    const rows = this.holdViews.map((r) => ({
      ...this.rowLine(r, r.askedLabel),
      issueDetail: r.holdReason
    }));
    return [...codes, ...rows];
  }

  get firmTableItems() {
    return this.firmFollowUpViews.map((f) => ({
      key: f.key,
      title: f.firmName,
      subtitle: f.contactEmail
        ? `${f.contactName} · ${f.contactEmail}`
        : "No Operations Contact",
      note: "",
      issueType: f.status,
      issueDetail: "",
      badges: [],
      lastText: f.questionsText
    }));
  }

  get mappingTableItems() {
    return this.mappingViews.map((m) => ({
      key: m.key,
      title: m.title,
      subtitle: "",
      note: "",
      issueType: m.subtitle,
      issueDetail: "",
      badges: [],
      lastText: ""
    }));
  }

  assignedLabel(item) {
    if (!item.assignedToId) {
      return "";
    }
    return item.assignedToId === (this.queue && this.queue.userId)
      ? "You"
      : item.assignedToName;
  }

  get codesLabel() {
    return `Dealer Code Review (${this.codeTableItems.length})`;
  }

  get rowsLabel() {
    return `Data Review (${this.decisionRowViews.length}${this.queue && this.queue.rowsTruncated ? "+" : ""})`;
  }

  get holdLabel() {
    return `On Hold (${this.holdViews.length + this.heldFollowUpViews.length})`;
  }

  get firmsLabel() {
    return `Email Firms (${this.firmFollowUpViews.length})`;
  }

  get mappingsLabel() {
    return `New File Format (${this.mappingViews.length})`;
  }

  /** Trades waiting behind codes, shown at the top of Dealer Code Review. */
  get heldNote() {
    const items = this.openFollowUpViews;
    const rows = items.reduce((n, f) => n + (f.heldRowCount || 0), 0);
    if (!rows) {
      return "";
    }
    const amount = items.reduce((n, f) => n + Number(f.heldAmount || 0), 0);
    return `${plural(rows, "row")} (${money(amount)} in trades) ${rows === 1 ? "is" : "are"} held until the ${plural(items.length, "code")} below ${items.length === 1 ? "is" : "are"} fixed.`;
  }

  get hasFiles() {
    return this.fileViews.length > 0;
  }

  // ------------------------------------------------------------------ cloud folders

  get cloudViews() {
    const items = (this.queue && this.queue.cloudSources) || [];
    return items.map((s) => ({
      ...s,
      key: "cloud:" + s.id,
      title: `${s.name}${s.folder ? " · " + s.folder : ""}`,
      statusText: pullText(s),
      failed: s.lastStatus === "Failed",
      isDaily: s.frequency === "Daily",
      hourValue:
        s.pullHour === null || s.pullHour === undefined
          ? undefined
          : String(s.pullHour),
      pullDisabled: this.busy || !s.active || s.lastStatus === "Pulling"
    }));
  }

  get hasCloudSources() {
    return this.cloudViews.length > 0;
  }

  get pullFrequencies() {
    return PULL_FREQUENCIES;
  }

  get pullHours() {
    return PULL_HOURS;
  }

  handlePullNow(event) {
    const sourceId = event.currentTarget.dataset.id;
    this.run(
      () => pullNow({ sourceId }),
      "Checking the folder for new files. The page updates when it is done."
    );
  }

  handlePullFrequency(event) {
    const sourceId = event.currentTarget.dataset.id;
    const frequency = event.detail.value;
    this.run(
      () => setPullSchedule({ sourceId, frequency, pullHour: null }),
      frequency === "Manual only"
        ? "This folder is now checked only when you click Pull now."
        : `This folder is now checked ${frequency.toLowerCase()}.`
    );
  }

  handlePullHour(event) {
    const sourceId = event.currentTarget.dataset.id;
    const pullHour = Number(event.detail.value);
    this.run(
      () => setPullSchedule({ sourceId, frequency: "Daily", pullHour }),
      `This folder is now checked daily at ${PULL_HOURS[pullHour].label}.`
    );
  }

  get working() {
    return !!(this.queue && this.queue.inFlight > 0);
  }

  get workingText() {
    if (this.live) {
      return `Working in the background (${this.queue.inFlight})… this page updates itself when it's done.`;
    }
    return this.pollTimer
      ? `Working in the background (${this.queue.inFlight})… this page refreshes itself.`
      : `Still working in the background (${this.queue.inFlight}). Click Refresh to check again.`;
  }

  get claudeLabel() {
    if (!this.queue) {
      return "";
    }
    return this.queue.claudeEnabled
      ? `Claude: ${this.queue.provider}`
      : "Claude: off";
  }

  // ------------------------------------------------------------------ selected item

  get selectedRow() {
    return this.allRowViews.find((r) => r.key === this.selectedKey);
  }

  get selectedIsOnHold() {
    const item = this.selectedItem;
    return !!(item && item.onHold);
  }

  get selectedIsOpen() {
    const item = this.selectedItem;
    return !!(item && !item.onHold);
  }

  get selectedFollowUp() {
    return this.followUpViews.find((f) => f.key === this.selectedKey);
  }

  get selectedMapping() {
    return this.mappingViews.find((m) => m.key === this.selectedKey);
  }

  get selectedFirm() {
    return this.firmFollowUpViews.find((f) => f.key === this.selectedKey);
  }

  get nothingSelected() {
    return (
      !this.selectedRow &&
      !this.selectedFollowUp &&
      !this.selectedMapping &&
      !this.selectedFirm
    );
  }

  /** The pending "mark as asked" prompt belongs to the firm shown. */
  get pendingAskHere() {
    const f = this.selectedFirm;
    return !!(this.pendingAsk && f && this.pendingAsk.firmId === f.firmId);
  }

  get selectedItem() {
    return this.selectedRow || this.selectedFollowUp;
  }

  /** What the detail pane shows the same way for a row and a code review. */
  get detail() {
    const r = this.selectedRow;
    const f = r ? undefined : this.selectedFollowUp;
    const item = r || f;
    if (!item) {
      return undefined;
    }
    const base = {
      onHold: !!item.onHold,
      holdTitle: item.holdTitle,
      holdReason: item.holdReason,
      askedLabel: item.askedLabel,
      assignedToName: item.assignedToName,
      hasConfidence: !!item.aiConfidence,
      aiConfidence: item.aiConfidence,
      confidenceBadge: CONFIDENCE_BADGE[item.aiConfidence] || "tv-chip",
      aiRequestId: item.aiRequestId,
      aiRequestName: item.aiRequestName,
      statusClass: item.onHold ? "tv-chip chip-hold" : "tv-chip chip-open"
    };
    if (r) {
      return {
        ...base,
        cssClass: "item-detail row-detail",
        kindLabel: r.isRoster ? "Roster change" : "Row decision",
        statusLabel: r.onHold ? "On hold" : r.issueType || "Data review",
        title: r.title,
        origin: `${r.rowType} · ${r.subtitle} · ${r.name}`,
        actionLabel: r.actionLabel
      };
    }
    return {
      ...base,
      cssClass: "item-detail followup-detail",
      kindLabel: "Code review",
      statusLabel: f.onHold ? "On hold" : f.reason,
      title: f.title,
      origin: `${f.firmName || "Unknown firm"} · code ${f.repCode} · ${f.heldSummary} · ${f.name}`,
      actionLabel: ""
    };
  }

  /** The selected row as one table line, with the cell that needs a person marked and labelled. */
  get rowCells() {
    const r = this.selectedRow;
    if (!r) {
      return [];
    }
    const notes = {};
    (r.flags || []).forEach((flag) => {
      const hit = CELL_FLAGS[flag];
      if (hit && !notes[hit[0]]) {
        notes[hit[0]] = hit[1];
      }
    });
    const amount =
      r.amount === null || r.amount === undefined ? "" : money(r.amount);
    return [
      { key: "date", label: "Date", value: dayText(r.tradeDate) },
      { key: "code", label: "Code", value: r.repCode },
      { key: "advisor", label: "Advisor", value: r.advisorName },
      { key: "firm", label: "Firm", value: r.firmName },
      { key: "fund", label: "Fund", value: r.fundName },
      { key: "amount", label: "Amount", value: amount }
    ]
      .filter((c) => c.value || notes[c.key])
      .map((c) => ({
        ...c,
        value: c.value || "(none)",
        note: notes[c.key] || "",
        cellClass:
          (notes[c.key] ? "slds-cell-wrap problem-cell" : "slds-cell-wrap") +
          (c.key === "amount" ? " amount-cell" : ""),
        headClass: c.key === "amount" ? "amount-cell" : ""
      }));
  }

  /** Branch and type, when the file gives them. */
  get rowExtra() {
    const r = this.selectedRow;
    if (!r) {
      return "";
    }
    return [
      r.branchName ? `Branch: ${r.branchName}` : "",
      r.transactionType ? `Type: ${r.transactionType}` : ""
    ]
      .filter((t) => t)
      .join(" · ");
  }

  /** "Firm · filled in from Claude" while the choice is still Claude's. */
  choiceLabel(base, choice, claude) {
    return claude && choice === claude
      ? `${base} · filled in from Claude`
      : base;
  }

  get firmChoiceLabel() {
    const r = this.selectedRow;
    return this.choiceLabel("Firm", this.firmChoice, r && r.aiFirmId);
  }

  get fundChoiceLabel() {
    const r = this.selectedRow;
    return this.choiceLabel("Fund", this.fundChoice, r && r.aiFundId);
  }

  get advisorChoiceLabel() {
    const r = this.selectedRow;
    return this.choiceLabel("Advisor", this.advisorChoice, r && r.aiAdvisorId);
  }

  /** What to ask the firm: Claude's homework for a row; Claude's (or the standard) question for a code review. */
  get claudeQuestion() {
    const r = this.selectedRow;
    if (r) {
      return this.hasSuggestion ? r.aiHomework || "" : "";
    }
    const f = this.selectedFollowUp;
    return f && !f.onHold ? f.question || "" : "";
  }

  get questionAskedLabel() {
    const f = this.selectedFollowUp;
    return f ? f.askedLabel : "";
  }

  get claudeState() {
    const item = this.selectedItem;
    if (!item || !this.queue) {
      return "";
    }
    if (!this.queue.claudeEnabled) {
      return "Claude is switched off. Decide from the evidence above.";
    }
    switch (item.aiStatus) {
      case "Suggested":
        return "";
      case "No Suggestion":
        return "Claude had no suggestion for this item.";
      case "Invalid":
        return "Claude's answer for this item broke the rules and was discarded. See the request log.";
      case "Failed":
        return "The request to Claude failed. See the request log.";
      default:
        return "Claude has not answered yet.";
    }
  }

  get hasSuggestion() {
    const item = this.selectedItem;
    return !!(item && item.aiStatus === "Suggested");
  }

  get suggestionText() {
    const item = this.selectedItem;
    return item ? item.aiSuggestion : "";
  }

  /** Claude's answer for each field: what it suggests, how sure it is and why. */
  get fieldTable() {
    const item = this.selectedItem;
    const lines = (item && item.fieldLines) || [];
    return lines.map((l, i) => ({
      ...l,
      key: String(i),
      valueClass: l.openQuestion ? "slds-text-color_weak open-question" : "",
      confidenceClass: CONFIDENCE_BADGE[l.confidence] || "tv-chip"
    }));
  }

  get hasFieldTable() {
    return this.fieldTable.length > 0;
  }

  get suggestedChoices() {
    const r = this.selectedRow;
    if (!r) {
      const f = this.selectedFollowUp;
      return f && f.aiAdvisorName
        ? [{ label: "Advisor", value: f.aiAdvisorName }]
        : [];
    }
    return [
      { label: "Firm", value: r.aiFirmName },
      { label: "Fund", value: r.aiFundName },
      { label: "Advisor", value: r.aiAdvisorName }
    ].filter((c) => !!c.value);
  }

  get firmOptions() {
    return (this.queue && this.queue.firmOptions) || [];
  }

  get fundOptions() {
    return (this.queue && this.queue.fundOptions) || [];
  }

  get acceptLabel() {
    const r = this.selectedRow;
    return r && r.isRoster ? "Approve roster entry" : this.groupLabel("Accept");
  }

  get acceptDisabled() {
    const r = this.selectedRow;
    if (!r || this.busy) {
      return true;
    }
    return (
      (r.isRoster && !r.canApprove) ||
      (r.needsFirm && !this.firmChoice) ||
      (r.needsFund && !this.fundChoice) ||
      (r.needsAdvisor && !this.advisorChoice)
    );
  }

  get decisionHelp() {
    const r = this.selectedRow;
    if (!r) {
      return "";
    }
    if (r.claudeAnswersIt) {
      return "Claude's choices are filled in. Change them if you disagree, then accept.";
    }
    if (r.needsFirm || r.needsFund || r.needsAdvisor) {
      return "Choose the answer yourself, then accept.";
    }
    if (r.isRoster) {
      return r.canApprove
        ? "Approve to make the changes listed above."
        : "This roster row cannot be approved as it stands. Reject it, or put it on hold and ask the dealer.";
    }
    return "Accept re-checks the row after the data has been fixed.";
  }

  get isMine() {
    const item = this.selectedItem;
    return !!(item && this.queue && item.assignedToId === this.queue.userId);
  }

  get isUnassigned() {
    const item = this.selectedItem;
    return !!(item && !item.assignedToId);
  }

  get assignedToOther() {
    const item = this.selectedItem;
    return !!(item && item.assignedToId && !this.isMine);
  }

  get hasHeldRows() {
    const f = this.selectedFollowUp;
    return !!(f && f.heldRows && f.heldRows.length);
  }

  get heldRowViews() {
    const f = this.selectedFollowUp;
    if (!f) {
      return [];
    }
    const codeNote = REASON_CODE_NOTES[f.reason] || "";
    return f.heldRows.map((h, i) => {
      // The advisor cell is the problem when the advisor named is not the holder, or a dormant code names no one.
      const advisorNote =
        f.reason === "Reassignment Suspected" && h.advisorName
          ? "Not the holder"
          : f.reason === "Code Dormant" && !h.advisorName
            ? "Not named"
            : "";
      return {
        ...h,
        key: String(i),
        tradeDate: dayText(h.tradeDate),
        typeText: h.rowType === "AUM" ? "AUM balance" : "Trade",
        waitText: h.waitsOnRoster ? "Waits for the roster change" : "",
        codeText: f.repCode,
        codeNote,
        codeClass: codeNote ? "problem-cell" : "",
        advisorText: h.advisorName || "None named",
        advisorNote,
        advisorClass:
          (advisorNote ? "slds-cell-wrap problem-cell" : "slds-cell-wrap") +
          (h.advisorName ? "" : " slds-text-color_weak"),
        fundText: h.fundName || "None given",
        amountText: money(h.amount)
      };
    });
  }

  /** Rows beyond the few listed. */
  get heldRowsNote() {
    const f = this.selectedFollowUp;
    if (!f || !f.heldRows) {
      return "";
    }
    const more = (f.heldRowCount || 0) - f.heldRows.length;
    return more > 0 ? `and ${plural(more, "more row")}` : "";
  }

  // ------------------------------------------------------------------ code review decisions

  get codeReviewHelp() {
    const f = this.selectedFollowUp;
    if (!f) {
      return "";
    }
    return f.rosterPartial
      ? `The options below apply to the ${plural(f.workableCount, "row")} not waiting for the roster change.`
      : `Choose one way to settle the ${plural(f.heldRowCount, "held row")}.`;
  }

  get rosterPartial() {
    const f = this.selectedFollowUp;
    return !!(f && f.rosterPartial);
  }

  get rosterInfo() {
    const f = this.selectedFollowUp;
    return !!(f && f.rosterInfo);
  }

  /** Why a waiting roster change holds nothing back here. */
  get rosterInfoText() {
    const f = this.selectedFollowUp;
    if (!f || !f.rosterInfo) {
      return "";
    }
    const why = f.rosterApprovable
      ? `none of these rows fall under it (they are dated before ${f.rosterDateText} or name someone other than ${f.rosterName})`
      : "it cannot be approved as it stands";
    return `A roster change for code ${f.repCode} is waiting (${f.rosterText}), but ${why}, so nothing here waits for it.`;
  }

  get rosterPartialText() {
    const f = this.selectedFollowUp;
    if (!f || !f.rosterPartial) {
      return "";
    }
    return `The firm's roster gives code ${f.repCode} to ${f.rosterName} from ${f.rosterDateText} (${f.rosterText}). ${plural(f.rosterCovered, "row")} dated from then that name ${f.rosterName} or no one wait for it. The other ${plural(f.workableCount, "row")} fall outside it, so you can settle them now.`;
  }

  /** A roster change for this code is waiting: it is decided first, and the review's own options are locked. */
  get rosterFirst() {
    const f = this.selectedFollowUp;
    return !!(f && f.rosterFirst);
  }

  get rosterKey() {
    const f = this.selectedFollowUp;
    return f ? f.rosterKey : "";
  }

  /** The roster change is in the current view (Mine or Unassigned may hide it). */
  get rosterVisible() {
    const key = this.rosterKey;
    return !!key && this.allRowViews.some((r) => r.key === key);
  }

  get creditHelp() {
    const f = this.selectedFollowUp;
    return f
      ? `Credits each held row 100% to the advisor chosen above, then matches it again. Use when the firm confirms who placed the trades. Only people who held code ${f.repCode} on every held row's date are listed.`
      : "";
  }

  get rematchHelp() {
    const f = this.selectedFollowUp;
    if (!f) {
      return "";
    }
    return f.rosterPartial
      ? `Not available while the roster change is waiting: approving it is the fix for code ${f.repCode}.`
      : `Use after code ${f.repCode} is set up or corrected in Salesforce (its Rep Code record and assignments). The held rows are matched again against it.`;
  }

  get sendHelp() {
    const f = this.selectedFollowUp;
    return f
      ? f.rosterPartial
        ? `The ${plural(f.workableCount, "row")} not waiting for the roster change move to Data Review to be accepted or rejected one at a time. This review stays open for the rest.`
        : `Closes this review without fixing the code. The ${plural(f.heldRowCount, "row")} move to Data Review to be accepted or rejected one at a time.`
      : "";
  }

  /** Jumps to a linked item (a roster change and the code review it settles). */
  handleGoTo(event) {
    this.select(event.currentTarget.dataset.key);
  }

  get creditLabel() {
    const f = this.selectedFollowUp;
    const n = f ? f.workableCount : 0;
    if (f && f.rosterPartial) {
      return n > 1 ? `Credit the other ${n} rows` : "Credit the other row";
    }
    return n > 1 ? `Credit all ${n} rows` : "Credit the row";
  }

  handleCreditChoice(event) {
    this.creditChoice = event.detail.value;
  }

  handleCredit() {
    const f = this.selectedFollowUp;
    this.run(
      () =>
        creditCodeReview({ followUpId: f.id, advisorId: this.creditChoice }),
      (n) =>
        bulkMessage(
          n,
          "Credited. The row is being re-matched.",
          "Credited {n} rows. They are being re-matched."
        )
    );
  }

  get confirmHolderHelp() {
    const f = this.selectedFollowUp;
    return f
      ? `Use when the firm confirms ${f.holderNames} still ${f.holderNames && f.holderNames.includes(" and ") ? "use" : "uses"} code ${f.repCode}. The confirmation is recorded on the assignment, so the code no longer counts as dormant, and the ${plural(f.heldRowCount, "held row")} are matched again and credited as usual.`
      : "";
  }

  handleConfirmHolder() {
    const f = this.selectedFollowUp;
    this.run(
      () => confirmHolder({ followUpId: f.id }),
      (n) =>
        bulkMessage(
          n,
          "Holder confirmed. The row is being re-matched.",
          "Holder confirmed. {n} rows are being re-matched."
        )
    );
  }

  handleRematch() {
    const f = this.selectedFollowUp;
    this.run(
      () => closeCodeReview({ followUpId: f.id, fixed: true }),
      "Re-matching the held rows against the fixed code."
    );
  }

  handleSendToReview() {
    const f = this.selectedFollowUp;
    this.run(
      () => closeCodeReview({ followUpId: f.id, fixed: false }),
      (n) =>
        bulkMessage(
          n,
          "The row is now in Data Review.",
          "{n} rows are now in Data Review."
        )
    );
  }

  /** The ways to settle the selected code review, one to choose; Claude's is marked and pre-chosen. */
  get fixOptions() {
    const f = this.selectedFollowUp;
    if (!f) {
      return [];
    }
    const options = [];
    const uses =
      f.holderNames && f.holderNames.includes(" and ") ? "use" : "uses";
    if (f.canConfirmHolder) {
      options.push({
        value: FIX_CONFIRM,
        title: `Confirm ${f.holderNames} still ${uses} code ${f.repCode}`,
        help: this.confirmHolderHelp,
        disabled: this.rosterFirst || this.rosterPartial,
        fromClaude:
          !!f.aiAdvisorName &&
          (f.holderNames || "").split(" and ").includes(f.aiAdvisorName)
      });
    }
    if (f.canCredit) {
      const fromClaude = !!claudeCredit(f);
      options.push({
        value: FIX_CREDIT,
        title: "Credit an advisor for these rows",
        help: this.creditHelp,
        disabled: this.rosterFirst,
        // With Confirm holder on offer, Claude's advisor is the holder to confirm, not a one-off credit.
        fromClaude: fromClaude && !f.canConfirmHolder,
        isCredit: true
      });
    }
    options.push({
      value: FIX_REMATCH,
      title: `I fixed code ${f.repCode} in Salesforce: re-match`,
      help: this.rematchHelp,
      disabled: this.rosterFirst || this.rosterPartial,
      fromClaude: false
    });
    options.push({
      value: FIX_SEND,
      title: "Decide rows one by one",
      help: this.sendHelp,
      disabled: this.rosterFirst,
      fromClaude: false
    });
    return options.map((o) => {
      const checked = o.value === this.fixChoice;
      return {
        ...o,
        isCredit: !!o.isCredit,
        // Written out with its leading space, so the title and the tag never run together.
        claudeTag: o.fromClaude ? " · Claude's answer" : "",
        checked,
        cardClass:
          "fix-option" +
          (checked ? " fix-option_selected" : "") +
          (o.disabled ? " fix-option_disabled" : "")
      };
    });
  }

  get selectedFix() {
    return this.fixOptions.find((o) => o.value === this.fixChoice);
  }

  get fixApplyLabel() {
    const f = this.selectedFollowUp;
    switch (this.fixChoice) {
      case FIX_CONFIRM:
        return `Confirm ${f ? f.holderNames : "holder"}`;
      case FIX_CREDIT:
        return this.creditLabel;
      case FIX_REMATCH:
        return "Re-match";
      case FIX_SEND:
        return "Send to Data Review";
      default:
        return "Choose a fix";
    }
  }

  get fixApplyDisabled() {
    const o = this.selectedFix;
    if (this.busy || !o || o.disabled) {
      return true;
    }
    return o.value === FIX_CREDIT && !this.creditChoice;
  }

  handleFixChoice(event) {
    this.fixChoice = event.target.value;
  }

  handleApplyFix() {
    switch (this.fixChoice) {
      case FIX_CONFIRM:
        this.handleConfirmHolder();
        break;
      case FIX_CREDIT:
        this.handleCredit();
        break;
      case FIX_REMATCH:
        this.handleRematch();
        break;
      case FIX_SEND:
        this.handleSendToReview();
        break;
      default:
        break;
    }
  }

  // ------------------------------------------------------------------ decision inputs

  handleFirmChoice(event) {
    this.firmChoice = event.detail.value;
  }

  handleFundChoice(event) {
    this.fundChoice = event.detail.value;
  }

  handleAdvisorChoice(event) {
    this.advisorChoice = event.detail.value;
  }

  handleRemember(event) {
    this.remember = event.target.checked;
  }

  // ------------------------------------------------------------------ actions

  async run(action, successMessage) {
    this.busy = true;
    try {
      const result = await action();
      this.toast(
        "success",
        typeof successMessage === "function"
          ? successMessage(result)
          : successMessage
      );
      await this.refreshAfterAction();
    } catch (e) {
      this.toast("error", errorText(e));
    } finally {
      this.busy = false;
    }
  }

  handleAccept() {
    const r = this.selectedRow;
    this.run(
      () =>
        decideRow({
          rowId: r.id,
          decision: "Accept",
          firmId: r.needsFirm ? this.firmChoice : null,
          fundId: r.needsFund ? this.fundChoice : null,
          advisorId: r.needsAdvisor ? this.advisorChoice : null,
          rememberChoice: r.canRemember && this.remember
        }),
      r.isRoster
        ? "Roster entry approved."
        : (n) =>
            bulkMessage(
              n,
              "Accepted. The row is being re-matched.",
              "Accepted {n} rows. They are being re-matched."
            )
    );
  }

  handleReject() {
    const r = this.selectedRow;
    this.run(
      () =>
        decideRow({
          rowId: r.id,
          decision: "Reject",
          firmId: null,
          fundId: null,
          advisorId: null,
          rememberChoice: false
        }),
      (n) =>
        bulkMessage(
          n,
          "Rejected. The row will not be loaded.",
          "Rejected {n} rows. They will not be loaded."
        )
    );
  }

  // ------------------------------------------------------------------ on hold

  handleOpenHold() {
    this.holdText = this.holdPrefill;
    this.showHold = true;
  }

  /** The question the dialog starts with: Claude's (or, for a code review, the standard one). */
  get holdPrefill() {
    const r = this.selectedRow;
    if (r) {
      return r.aiHomework || "";
    }
    const f = this.selectedFollowUp;
    return f ? f.holdReason || f.question || "" : "";
  }

  get holdIntro() {
    const f = this.selectedRow ? undefined : this.selectedFollowUp;
    if (f) {
      return `Code ${f.repCode} moves to the On Hold tab until ${f.firmName || "the firm"} answers. Its rows stay held, and you can still settle it from there at any time. The question goes in the firm's next follow-up email.`;
    }
    return "The row waits on the On Hold tab until you accept, reject or release it. Say what needs to be found out; it becomes the question in the firm's follow-up email.";
  }

  get holdPrefillText() {
    const r = this.selectedRow;
    return r || (this.selectedFollowUp && this.selectedFollowUp.aiHomework)
      ? "Filled in from Claude's suggestion. Edit it as needed."
      : "Filled in with the standard question for this code. Edit it as needed.";
  }

  handleCloseHold() {
    this.showHold = false;
  }

  handleHoldText(event) {
    this.holdText = event.detail.value || "";
  }

  get holdDisabled() {
    return this.busy || !this.holdText.trim();
  }

  get holdPrefilled() {
    return !!this.holdPrefill;
  }

  async handleConfirmHold() {
    const r = this.selectedRow;
    this.showHold = false;
    if (!r) {
      const f = this.selectedFollowUp;
      await this.run(
        () => holdCodeReview({ followUpId: f.id, homework: this.holdText }),
        `Code ${f.repCode} is on hold. Find it on the On Hold tab.`
      );
      return;
    }
    await this.run(
      () => holdRow({ rowId: r.id, homework: this.holdText }),
      (n) =>
        bulkMessage(
          n,
          "On hold. Find it on the On Hold tab.",
          "{n} rows on hold. Find them on the On Hold tab."
        )
    );
  }

  handleRelease() {
    const r = this.selectedRow;
    if (!r) {
      const f = this.selectedFollowUp;
      this.run(
        () => releaseCodeReviewHold({ followUpId: f.id }),
        `Released. Code ${f.repCode} is back in Dealer Code Review.`
      );
      return;
    }
    this.run(
      () => releaseHold({ rowId: r.id }),
      (n) =>
        bulkMessage(
          n,
          "Released. The row is back in Data Review.",
          "Released {n} rows. They are back in Data Review."
        )
    );
  }

  // ------------------------------------------------------------------ asking the firm

  /** Drafts one email for the firm's questions and opens it in Salesforce's Send Email window. */
  async handleEmailFirm(event) {
    const firmId = event.currentTarget.dataset.id;
    this.busy = true;
    try {
      const draft = await draftFirmEmail({ firmId });
      if (draft.note) {
        this.toast("info", draft.note);
      }
      this[NavigationMixin.Navigate]({
        type: "standard__quickAction",
        attributes: { apiName: "Global.SendEmail" },
        state: {
          recordId: firmId,
          defaultFieldValues: encodeDefaultFieldValues({
            ToAddress: draft.toAddress,
            Subject: draft.subject,
            HtmlBody: draft.htmlBody,
            RelatedToId: firmId
          })
        }
      });
      const firm = this.firmFollowUpViews.find((f) => f.firmId === firmId);
      this.pendingAsk = {
        firmId,
        firmName: firm ? firm.firmName : "",
        itemIds: draft.itemIds,
        count: draft.itemIds.length
      };
    } catch (e) {
      this.toast("error", errorText(e));
    } finally {
      this.busy = false;
    }
  }

  get pendingAskText() {
    const p = this.pendingAsk;
    if (!p) {
      return "";
    }
    const questions = p.count === 1 ? "1 question" : `${p.count} questions`;
    return `After you send the email to ${p.firmName}, mark its ${questions} as asked so the app can remind you if there is no answer.`;
  }

  async handleMarkAsked() {
    const ids = this.pendingAsk.itemIds;
    this.pendingAsk = undefined;
    await this.run(() => markAsked({ itemIds: ids }), "Marked as asked.");
  }

  handleNotSent() {
    this.pendingAsk = undefined;
  }

  handleAssignToMe() {
    const item = this.selectedItem;
    this.run(
      () => setAssignment({ recordId: item.id, assignToMe: true }),
      "Assigned to you."
    );
  }

  handleUnassign() {
    const item = this.selectedItem;
    this.run(
      () => setAssignment({ recordId: item.id, assignToMe: false }),
      "Unassigned."
    );
  }

  handleActivateMapping() {
    const m = this.selectedMapping;
    this.run(
      () => activateMapping({ profileId: m.profileId }),
      "Mapping activated. The waiting file is being processed."
    );
  }

  handleOpenRecord(event) {
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: event.currentTarget.dataset.id,
        actionName: "view"
      }
    });
  }

  toast(variant, message) {
    this.dispatchEvent(
      new ShowToastEvent({
        title:
          variant === "success"
            ? "Done"
            : variant === "info"
              ? "Note"
              : "Could not complete that",
        message,
        variant
      })
    );
  }

  // ------------------------------------------------------------------ upload

  get uploadFirmOptions() {
    const firms = (this.queue && this.queue.sourceFirms) || [];
    return [
      ...firms.map((f) => ({ label: f, value: f })),
      { label: "A new dealer…", value: OTHER_FIRM }
    ];
  }

  get uploadIsOther() {
    return this.uploadFirm === OTHER_FIRM;
  }

  get uploadFirmCode() {
    return this.uploadIsOther
      ? this.uploadOtherFirm.trim().toUpperCase()
      : this.uploadFirm;
  }

  get uploadFileName() {
    return this.uploadFileRef ? this.uploadFileRef.name : "No file chosen";
  }

  get uploadDisabled() {
    return this.uploading || !this.uploadFirmCode || !this.uploadFileRef;
  }

  handleOpenUpload() {
    this.showUpload = true;
    this.uploadError = undefined;
  }

  handleCloseUpload() {
    this.showUpload = false;
    this.uploadFileRef = undefined;
    this.uploadError = undefined;
  }

  handleUploadFirm(event) {
    this.uploadFirm = event.detail.value;
  }

  handleUploadOtherFirm(event) {
    this.uploadOtherFirm = event.detail.value || "";
  }

  handleUploadFile(event) {
    const files = event.target.files;
    this.uploadFileRef = files && files.length ? files[0] : undefined;
    this.uploadError =
      this.uploadFileRef && this.uploadFileRef.size > MAX_UPLOAD_BYTES
        ? "The file is larger than 1024 KB. Ask the sender to split it."
        : undefined;
  }

  readAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(base64Of(reader.result));
      reader.onerror = () =>
        reject(reader.error || new Error("The file could not be read."));
      reader.readAsDataURL(file);
    });
  }

  async handleUpload() {
    if (this.uploadError) {
      return;
    }
    this.uploading = true;
    try {
      const content = await this.readAsBase64(this.uploadFileRef);
      const receipt = await uploadFile({
        sourceFirm: this.uploadFirmCode,
        fileName: this.uploadFileRef.name,
        base64Content: content
      });
      this.toast("success", receipt.message);
      this.handleCloseUpload();
      this.activeTab = "files";
      await this.refreshAfterAction();
    } catch (e) {
      this.uploadError = errorText(e);
    } finally {
      this.uploading = false;
    }
  }
}
