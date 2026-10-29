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

// While files, rows or Claude requests are still being worked on in the background, the queue refreshes
// itself every few seconds, for up to three minutes after the last action.
export const POLL_MS = 5000;
export const MAX_POLLS = 36;
export const MAX_UPLOAD_BYTES = 1024 * 1024;
// A question asked this long ago without an answer gets a reminder label.
export const NUDGE_DAYS = 3;
const DAY_MS = 24 * 60 * 60 * 1000;
const ACTION_LABELS = {
  Accept: "Claude recommends: Accept",
  Reject: "Claude recommends: Reject",
  Hold: "Claude recommends: Put on hold"
};
const OTHER_FIRM = "__other__";
const SCOPES = [
  { label: "All", value: "all" },
  { label: "Mine", value: "mine" },
  { label: "Unassigned", value: "unassigned" }
];
const CONFIDENCE_CLASS = {
  High: "slds-theme_success",
  Medium: "slds-theme_warning",
  Low: ""
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

  scopeOptions = SCOPES;

  connectedCallback() {
    this.load();
  }

  disconnectedCallback() {
    this.stopPolling();
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
      this.pollTimer = setInterval(() => {
        this.polls += 1;
        this.load();
      }, POLL_MS);
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
    return this.groupLabel("Release");
  }

  /** When Claude's suggestion arrives after the row was opened, fill in any choice the reviewer has not made. */
  fillFromClaude() {
    const row = this.selectedRow;
    if (!row) {
      this.creditChoice =
        this.creditChoice || claudeCredit(this.selectedFollowUp);
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
        askedLabel: askedText(r.askedAt),
        hasPlan: !!(r.isRoster && r.approvalPlan && r.approvalPlan.length),
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
      creditOptions: f.advisorOptions || [],
      hasConfidence: !!f.aiConfidence,
      confidenceClass: CONFIDENCE_CLASS[f.aiConfidence] || "",
      assignedLabel: this.assignedLabel(f),
      askedLabel: askedText(f.askedAt)
    }));
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
          : `${f.status} · ${f.rowCount} rows: ${f.matchedCount || 0} matched, ${f.reviewCount || 0} to review, ${f.heldCount || 0} held, ${f.errorCount || 0} invalid`
    }));
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
    const codes = this.followUpViews.map((f) => ({
      key: f.key,
      title: `Code ${f.repCode}`,
      subtitle: f.firmName || "Unknown firm",
      note:
        f.askedLabel || (f.assignedLabel ? `Assigned: ${f.assignedLabel}` : ""),
      issueType: f.reason,
      issueDetail: "",
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
    }));
    const rows = this.codeRowViews.map((r) => ({
      ...this.rowLine(r),
      group: "Roster and code decisions"
    }));
    return this.grouped([...codes, ...rows], (l) => l.group);
  }

  /** Needs Decision: everything else (firm, fund and other data questions), grouped by file. */
  get decisionTableItems() {
    return this.grouped(
      this.decisionRowViews.map((r) => ({
        ...this.rowLine(r),
        group: `${r.sourceFirm || "File"} · ${r.fileName || ""}`
      })),
      (l) => l.group
    );
  }

  get holdTableItems() {
    return this.holdViews.map((r) => ({
      ...this.rowLine(r, r.askedLabel),
      issueDetail: r.holdReason
    }));
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
    return `Needs Decision (${this.decisionRowViews.length}${this.queue && this.queue.rowsTruncated ? "+" : ""})`;
  }

  get holdLabel() {
    return `On Hold (${this.holdViews.length})`;
  }

  get firmsLabel() {
    return `Email Firms (${this.firmFollowUpViews.length})`;
  }

  get mappingsLabel() {
    return `New File Format (${this.mappingViews.length})`;
  }

  /** Trades waiting behind codes, shown at the top of Dealer Code Review. */
  get heldNote() {
    const items = (this.queue && this.queue.followUps) || [];
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

  get working() {
    return !!(this.queue && this.queue.inFlight > 0);
  }

  get workingText() {
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
    const r = this.selectedRow;
    return !!(r && r.onHold);
  }

  get selectedIsOpen() {
    const r = this.selectedRow;
    return !!(r && !r.onHold);
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

  get fileFields() {
    const r = this.selectedRow;
    if (!r) {
      return [];
    }
    return [
      { label: "Firm", value: r.firmName },
      { label: "Rep code", value: r.repCode },
      { label: "Advisor", value: r.advisorName },
      { label: "Branch", value: r.branchName },
      { label: "Fund", value: r.fundName },
      { label: "Date", value: r.tradeDate },
      { label: "Type", value: r.transactionType },
      {
        label: "Amount",
        value:
          r.amount === null || r.amount === undefined ? "" : money(r.amount)
      }
    ]
      .filter(
        (f) => f.value !== null && f.value !== undefined && f.value !== ""
      )
      .map((f) => ({
        ...f,
        labelKey: "l-" + f.label,
        valueKey: "v-" + f.label
      }));
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
      confidenceClass: "slds-badge " + (CONFIDENCE_CLASS[l.confidence] || "")
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

  get confidenceClass() {
    const item = this.selectedItem;
    return item ? CONFIDENCE_CLASS[item.aiConfidence] || "" : "";
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
    return f
      ? f.heldRows.map((h, i) => ({
          ...h,
          key: String(i),
          typeText: h.rowType === "AUM" ? "AUM balance" : "Trade",
          advisorText: h.advisorName || "None named",
          fundText: h.fundName || "None given",
          amountText: money(h.amount)
        }))
      : [];
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
    return f.canCredit
      ? `Credit one advisor who held code ${f.repCode} on every held row's date: each row is credited 100% to them and re-matched. Or fix the code in Salesforce and re-match.`
      : `Set up or correct code ${f.repCode} in Salesforce, then re-match. If it cannot be fixed, send the rows to Needs Decision.`;
  }

  get creditLabel() {
    const f = this.selectedFollowUp;
    const n = f ? f.heldRowCount : 0;
    return n > 1 ? `Credit all ${n} rows` : "Credit the row";
  }

  get creditDisabled() {
    return this.busy || !this.creditChoice;
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
          "The row is now in Needs Decision.",
          "{n} rows are now in Needs Decision."
        )
    );
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
    const r = this.selectedRow;
    this.holdText = (r && r.aiHomework) || "";
    this.showHold = true;
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
    const r = this.selectedRow;
    return !!(r && r.aiHomework);
  }

  async handleConfirmHold() {
    const r = this.selectedRow;
    this.showHold = false;
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
    this.run(
      () => releaseHold({ rowId: r.id }),
      (n) =>
        bulkMessage(
          n,
          "Released. The row is back in Needs Decision.",
          "Released {n} rows. They are back in Needs Decision."
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
