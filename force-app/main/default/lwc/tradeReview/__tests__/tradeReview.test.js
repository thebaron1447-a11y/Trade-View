import { createElement } from "lwc";
import TradeReview, {
  errorText,
  base64Of,
  POLL_MS,
  MAX_POLLS,
  askedText,
  bulkMessage
} from "c/tradeReview";
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
import { encodeDefaultFieldValues } from "lightning/pageReferenceUtils";
import { navigate } from "lightning/navigation";

jest.mock(
  "@salesforce/apex/ReviewController.getQueue",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.decideRow",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.setAssignment",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.activateMapping",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.uploadFile",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
// The standard stub ignores navigation; this one records every page reference.
jest.mock("lightning/navigation", () => {
  const Navigate = Symbol("Navigate");
  const recorder = jest.fn();
  const NavigationMixin = (Base) =>
    class extends Base {
      [Navigate](pageRef) {
        recorder(pageRef);
      }
    };
  NavigationMixin.Navigate = Navigate;
  return { NavigationMixin, navigate: recorder };
});
jest.mock(
  "@salesforce/apex/ReviewController.holdRow",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.releaseHold",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.draftFirmEmail",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.markAsked",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReviewController.getIssueRows",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const ME = "005000000000001AAA";

function kestrelRow(overrides) {
  return {
    id: "a0E000000000001AAA",
    name: "ISR-0000001",
    batchId: "a0C000000000001AAA",
    sourceFirm: "KESTREL",
    fileName: "kestrel_export.csv",
    rowNumber: 1,
    rowType: "Trade",
    isRoster: false,
    firmName: "Kestrel Capital",
    repCode: "1001",
    advisorName: "Ryan Chen",
    fundName: "Wealth World Fund - Series A",
    amount: 50000,
    flags: ["FIRM_AMBIGUOUS"],
    reasons: ["The firm name fits more than one firm"],
    issueType: "Firm unclear",
    issueCount: 1,
    isCodeIssue: false,
    aiStatus: "Suggested",
    aiConfidence: "High",
    aiSuggestion:
      "Ryan Chen works at the Calgary branch of Kestrel Capital Inc.",
    aiFirmId: "001000000000001AAA",
    aiFirmName: "Kestrel Capital Inc.",
    aiRequestId: "a0F000000000001AAA",
    aiRequestName: "AIR-00001",
    needsFirm: true,
    needsFund: false,
    needsAdvisor: false,
    canRemember: false,
    claudeAnswersIt: true,
    advisorOptions: [],
    ...overrides
  };
}

function queue(overrides) {
  return {
    rows: [kestrelRow()],
    followUps: [
      {
        id: "a0D000000000001AAA",
        name: "CFU-00001",
        repCode: "5521",
        firmName: "Northgate Wealth Partners",
        reason: "Code Dormant",
        status: "Open",
        heldRowCount: 1,
        heldAmount: 25000,
        aiStatus: "Suggested",
        aiConfidence: "Medium",
        aiSuggestion: "Tom Reilly most likely still holds 5521.",
        aiAdvisorName: "Tom Reilly",
        heldRows: [
          {
            tradeDate: "2026-09-15",
            issue: "The code has been dormant and the row names no advisor",
            advisorName: null,
            fundName: "Wealth World ETF",
            amount: 25000
          }
        ]
      }
    ],
    mappings: [],
    recentFiles: [],
    firmOptions: [
      { label: "Kestrel Capital Inc.", value: "001000000000001AAA" },
      { label: "Kestrel Capital Ltd.", value: "001000000000002AAA" }
    ],
    fundOptions: [
      { label: "Wealth World Fund - Series A", value: "01t000000000001AAA" }
    ],
    sourceFirms: ["BARDER", "KESTREL"],
    inFlight: 0,
    claudeEnabled: true,
    provider: "Models API",
    userId: ME,
    rowsTruncated: false,
    ...overrides
  };
}

async function flush() {
  for (let i = 0; i < 5; i++) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

async function openTab(element, value) {
  const tab = [...element.shadowRoot.querySelectorAll("lightning-tab")].find(
    (t) => t.value === value
  );
  tab.dispatchEvent(new CustomEvent("active"));
  await flush();
}

/** Renders the app and opens a tab (Needs Decision unless another is named). */
async function render(tab = "rows") {
  const element = createElement("c-trade-review", { is: TradeReview });
  document.body.appendChild(element);
  await flush();
  if (tab) {
    await openTab(element, tab);
  }
  return element;
}

function table(element, cls) {
  return element.shadowRoot.querySelector(`c-review-queue-table.${cls}`);
}

/** Clicks an item in a tab's queue table, as the table does. */
async function choose(element, cls, key) {
  table(element, cls).dispatchEvent(
    new CustomEvent("select", { detail: { key } })
  );
  await flush();
}

function button(element, cls) {
  return element.shadowRoot.querySelector(`lightning-button.${cls}`);
}

describe("c-trade-review", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  it("shows the queue and selects the first row with Claude's choice filled in", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render();

    expect(getQueue).toHaveBeenCalledWith({ scope: "all" });
    const tabs = [...element.shadowRoot.querySelectorAll("lightning-tab")].map(
      (t) => t.label
    );
    expect(tabs).toEqual([
      "Dealer Code Review (1)",
      "Needs Decision (1)",
      "On Hold (0)",
      "Email Firms (0)",
      "New File Format (0)",
      "Recent Files"
    ]);
    expect(element.shadowRoot.querySelector(".row-detail h2").textContent).toBe(
      "KESTREL · row 1"
    );
    expect(
      element.shadowRoot.querySelector(".row-detail .suggestion").textContent
    ).toContain("Calgary branch");
    expect(
      element.shadowRoot.querySelector("lightning-combobox.firm-choice").value
    ).toBe("001000000000001AAA");
    expect(button(element, "accept").disabled).toBe(false);
  });

  it("accepts with Claude's firm and refreshes", async () => {
    getQueue.mockResolvedValue(queue());
    decideRow.mockResolvedValue(undefined);
    const element = await render();

    button(element, "accept").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(decideRow).toHaveBeenCalledWith({
      rowId: "a0E000000000001AAA",
      decision: "Accept",
      firmId: "001000000000001AAA",
      fundId: null,
      advisorId: null,
      rememberChoice: false
    });
    expect(getQueue).toHaveBeenCalledTimes(2);
  });

  it("sends the reviewer's own firm when they change it", async () => {
    getQueue.mockResolvedValue(queue());
    decideRow.mockResolvedValue(undefined);
    const element = await render();

    const combo = element.shadowRoot.querySelector(
      "lightning-combobox.firm-choice"
    );
    combo.dispatchEvent(
      new CustomEvent("change", { detail: { value: "001000000000002AAA" } })
    );
    await flush();
    button(element, "accept").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(decideRow.mock.calls[0][0].firmId).toBe("001000000000002AAA");
  });

  it("cannot accept until a needed fund is chosen, and remembers the spelling when asked", async () => {
    const row = kestrelRow({
      flags: ["FUND_UNRESOLVED"],
      reasons: ["The fund name is not one we know"],
      needsFirm: false,
      needsFund: true,
      canRemember: true,
      aiStatus: "No Suggestion",
      aiFirmId: null,
      claudeAnswersIt: false
    });
    getQueue.mockResolvedValue(queue({ rows: [row] }));
    decideRow.mockResolvedValue(undefined);
    const element = await render();

    expect(button(element, "accept").disabled).toBe(true);
    expect(element.shadowRoot.querySelector(".claude-state").textContent).toBe(
      "Claude had no suggestion for this item."
    );

    element.shadowRoot
      .querySelector("lightning-combobox.fund-choice")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: "01t000000000001AAA" } })
      );
    const remember = element.shadowRoot.querySelector(
      "lightning-input.remember"
    );
    remember.checked = true;
    remember.dispatchEvent(new CustomEvent("change"));
    await flush();
    expect(button(element, "accept").disabled).toBe(false);

    button(element, "accept").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(decideRow.mock.calls[0][0]).toEqual({
      rowId: row.id,
      decision: "Accept",
      firmId: null,
      fundId: "01t000000000001AAA",
      advisorId: null,
      rememberChoice: true
    });
  });

  it("shows the server's refusal as an error toast and keeps the row", async () => {
    getQueue.mockResolvedValue(queue());
    decideRow.mockRejectedValue({
      body: {
        message: "Only rows in Needs Review can be accepted or rejected."
      }
    });
    const element = await render();
    const toasts = [];
    element.addEventListener("lightning__showtoast", (e) =>
      toasts.push(e.detail)
    );

    button(element, "accept").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(toasts).toHaveLength(1);
    expect(toasts[0].variant).toBe("error");
    expect(toasts[0].message).toBe(
      "Only rows in Needs Review can be accepted or rejected."
    );
    expect(getQueue).toHaveBeenCalledTimes(1);
    expect(button(element, "accept").disabled).toBe(false);
  });

  it("fills in Claude's firm when the suggestion arrives while the row is open", async () => {
    jest.useFakeTimers();
    getQueue.mockResolvedValueOnce(
      queue({
        inFlight: 1,
        rows: [
          kestrelRow({
            aiStatus: null,
            aiFirmId: null,
            aiFirmName: null,
            claudeAnswersIt: false
          })
        ]
      })
    );
    getQueue.mockResolvedValue(queue());
    const element = await render();
    expect(
      element.shadowRoot.querySelector("lightning-combobox.firm-choice").value
    ).toBeUndefined();
    expect(element.shadowRoot.querySelector(".claude-state").textContent).toBe(
      "Claude has not answered yet."
    );

    jest.advanceTimersByTime(POLL_MS);
    await flush();
    expect(
      element.shadowRoot.querySelector("lightning-combobox.firm-choice").value
    ).toBe("001000000000001AAA");
  });

  it("rejects a row", async () => {
    getQueue.mockResolvedValue(queue());
    decideRow.mockResolvedValue(undefined);
    const element = await render();

    button(element, "reject").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(decideRow).toHaveBeenCalledWith({
      rowId: "a0E000000000001AAA",
      decision: "Reject",
      firmId: null,
      fundId: null,
      advisorId: null,
      rememberChoice: false
    });
  });

  it("assigns and unassigns", async () => {
    getQueue.mockResolvedValueOnce(queue());
    getQueue.mockResolvedValue(
      queue({
        rows: [kestrelRow({ assignedToId: ME, assignedToName: "Greg" })]
      })
    );
    setAssignment.mockResolvedValue(undefined);
    const element = await render();

    expect(button(element, "unassign")).toBeNull();
    button(element, "assign").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(setAssignment).toHaveBeenCalledWith({
      recordId: "a0E000000000001AAA",
      assignToMe: true
    });

    expect(button(element, "assign")).toBeNull();
    button(element, "unassign").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(setAssignment).toHaveBeenLastCalledWith({
      recordId: "a0E000000000001AAA",
      assignToMe: false
    });
  });

  it("opens on Dealer Code Review, with Needs Decision in the same table form", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render(null);

    expect(
      element.shadowRoot.querySelector("lightning-tabset").activeTabValue
    ).toBe("codes");
    expect(element.shadowRoot.querySelector(".followup-detail")).not.toBeNull();

    await openTab(element, "rows");
    const items = table(element, "rows-table").items;
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      key: "row:a0E000000000001AAA",
      title: "KESTREL · row 1",
      issueType: "Firm unclear",
      lastText: "$50,000.00",
      groupLabel: "KESTREL · kestrel_export.csv"
    });
    expect(items[0].badges.map((b) => b.label)).toEqual(["Claude: High"]);
    expect(table(element, "rows-table").selectedKey).toBe(
      "row:a0E000000000001AAA"
    );
  });

  it("puts code issues in Dealer Code Review and everything else in Needs Decision", async () => {
    getQueue.mockResolvedValue(
      queue({
        rows: [
          kestrelRow(),
          kestrelRow({
            id: "a0E000000000002AAA",
            headline: "Priya Nair · Rep code mismatch on 2210",
            isCodeIssue: true,
            isRoster: true,
            issueType: "New code holder",
            issueCount: 2
          })
        ]
      })
    );
    const element = await render("codes");

    const codes = table(element, "codes-table").items;
    expect(codes.map((i) => i.title)).toEqual([
      "Code 5521",
      "Priya Nair · Rep code mismatch on 2210"
    ]);
    expect(codes.map((i) => i.groupLabel)).toEqual([
      "Codes to fix",
      "Roster and code decisions"
    ]);
    expect(codes[1]).toMatchObject({
      issueType: "New code holder",
      issueDetail: "+1 more",
      lastText: "Roster"
    });
    await openTab(element, "rows");
    expect(table(element, "rows-table").items.map((i) => i.title)).toEqual([
      "KESTREL · row 1"
    ]);
    expect(
      [...element.shadowRoot.querySelectorAll("lightning-tab")].map(
        (t) => t.label
      )
    ).toEqual([
      "Dealer Code Review (2)",
      "Needs Decision (1)",
      "On Hold (0)",
      "Email Firms (0)",
      "New File Format (0)",
      "Recent Files"
    ]);
  });

  it("shows rows that share an issue as one line, and decides them together", async () => {
    const group = kestrelRow({
      id: "a0E000000000007AAA",
      sourceFirm: "BARDER",
      headline: 'Unknown fund · "Zephyr Growth Pool"',
      needsFirm: false,
      needsFund: true,
      claudeAnswersIt: false,
      aiFundId: "01t000000000001AAA",
      issueType: "Unknown fund",
      groupCount: 37,
      groupAmount: 412000,
      groupFileCount: 3
    });
    getQueue.mockResolvedValue(queue({ rows: [group] }));
    getIssueRows.mockResolvedValue([
      {
        id: "a0E000000000007AAA",
        fileName: "barder_trades_2026-10-05.csv",
        rowNumber: 6,
        tradeDate: "2026-10-01",
        repCode: "457",
        advisorName: "Julia Morales",
        firmName: "Barder & Company",
        fundName: "Zephyr Growth Pool",
        amount: 12500
      },
      {
        id: "a0E000000000008AAA",
        fileName: "barder_trades_2026-10-06.csv",
        rowNumber: 2,
        tradeDate: "2026-10-02",
        repCode: "457",
        advisorName: "Julia Morales",
        firmName: "Barder & Company",
        fundName: "Zephyr Growth Pool",
        amount: 8000
      }
    ]);
    decideRow.mockResolvedValue(37);
    const element = await render();
    const handler = jest.fn();
    element.addEventListener("lightning__showtoast", handler);

    expect(table(element, "rows-table").items[0]).toMatchObject({
      title: 'Unknown fund · "Zephyr Growth Pool"',
      subtitle: "BARDER · 3 files",
      lastText: "37 rows · $412,000.00"
    });
    expect(getIssueRows).toHaveBeenCalledWith({ rowId: "a0E000000000007AAA" });
    expect(
      element.shadowRoot.querySelector(".group-summary").textContent
    ).toContain(
      "This issue affects 37 rows ($412,000.00) across 3 files. Your decision applies to all of them."
    );
    const listed = element.shadowRoot.querySelectorAll(".issue-rows tbody tr");
    expect(listed).toHaveLength(2);
    expect(listed[1].querySelector("td").textContent).toBe(
      "barder_trades_2026-10-06.csv · row 2"
    );
    expect(button(element, "accept").label).toBe("Accept all 37");
    expect(button(element, "reject").label).toBe("Reject all 37");
    expect(button(element, "hold").label).toBe("Put all 37 on hold");

    button(element, "accept").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(decideRow).toHaveBeenCalledWith({
      rowId: "a0E000000000007AAA",
      decision: "Accept",
      firmId: null,
      fundId: "01t000000000001AAA",
      advisorId: null,
      rememberChoice: false
    });
    expect(handler.mock.calls[0][0].detail.message).toBe(
      "Accepted 37 rows. They are being re-matched."
    );
  });

  it("shows a follow-up with its held trades", async () => {
    getQueue.mockResolvedValue(queue({ rows: [] }));
    const element = await render("codes");

    expect(
      element.shadowRoot.querySelector(".followup-detail h2").textContent
    ).toBe("Code 5521 · Northgate Wealth Partners");
    const held = element.shadowRoot.querySelectorAll(
      ".followup-detail .held-table tbody tr"
    );
    expect(held).toHaveLength(1);
    expect(held[0].querySelectorAll("td")[1].textContent).toBe(
      "The code has been dormant and the row names no advisor"
    );
    const codes = table(element, "codes-table").items;
    expect(codes).toHaveLength(1);
    expect(codes[0]).toMatchObject({
      issueType: "Code Dormant",
      lastText: "1 · $25,000.00"
    });
    expect(table(element, "codes-table").selectedKey).toBe(
      "fu:a0D000000000001AAA"
    );
    expect(
      element.shadowRoot.querySelector(".followup-detail .suggestion")
        .textContent
    ).toContain("Tom Reilly");
  });

  it("says how many trades are held behind the codes", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render("codes");

    expect(
      element.shadowRoot.querySelector(".held-note").textContent
    ).toContain("1 trade ($25,000.00) are held until 1 code below are fixed.");
  });

  it("switching tabs shows that tab's first item", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render();
    expect(element.shadowRoot.querySelector(".row-detail")).not.toBeNull();

    await openTab(element, "codes");
    expect(element.shadowRoot.querySelector(".row-detail")).toBeNull();
    expect(element.shadowRoot.querySelector(".followup-detail")).not.toBeNull();

    await openTab(element, "mappings");
    expect(
      element.shadowRoot.querySelector(".nothing-selected")
    ).not.toBeNull();
  });

  it("titles rows by their root cause and lists each note once", async () => {
    getQueue.mockResolvedValue(
      queue({
        rows: [
          kestrelRow({
            headline: "Ryan Chen · Which Kestrel firm?",
            origin: "KESTREL · row 1 · kestrel_export.csv",
            noteLines: [
              "Kestrel Capital fits two firms.",
              "Ryan Chen is at both."
            ]
          })
        ]
      })
    );
    const element = await render();

    expect(
      element.shadowRoot.querySelector(".row-detail h2").textContent.trim()
    ).toBe("Ryan Chen · Which Kestrel firm?");
    expect(
      element.shadowRoot.querySelector(".row-detail .origin").textContent
    ).toContain("KESTREL · row 1 · kestrel_export.csv");
    const why = [
      ...element.shadowRoot.querySelectorAll(".row-detail .reasons li")
    ].map((li) => li.textContent);
    expect(why).toEqual([
      "Kestrel Capital fits two firms.",
      "Ryan Chen is at both."
    ]);
  });

  it("shows Claude's answer per field as a table with its recommendation", async () => {
    getQueue.mockResolvedValue(
      queue({
        rows: [
          kestrelRow({
            aiAction: "Accept",
            fieldLines: [
              {
                field: "Firm",
                value: "Kestrel Capital Inc.",
                confidence: "High",
                reason: "Ryan Chen works at the Calgary branch."
              }
            ]
          })
        ]
      })
    );
    const element = await render();

    expect(
      element.shadowRoot.querySelector(".row-detail .ai-action").textContent
    ).toContain("Claude recommends: Accept");
    const cells = [
      ...element.shadowRoot.querySelectorAll(".field-table tbody td")
    ].map((td) => td.textContent);
    expect(cells).toEqual([
      "Firm",
      "Kestrel Capital Inc.",
      "High",
      "Ryan Chen works at the Calgary branch."
    ]);
    expect(element.shadowRoot.querySelector(".row-detail .choice")).toBeNull();
  });

  it("keeps a space between a label and its value", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render();
    const choice = element.shadowRoot.querySelector(".row-detail .choice");
    expect(choice.querySelector(".choice-label").textContent).toBe("Firm:");
    expect(choice.querySelector(".choice-label").className).toContain(
      "choice-label"
    );
    expect(choice.querySelector(".choice-value").textContent).toBe(
      "Kestrel Capital Inc."
    );
  });

  it("puts a row on hold with Claude's homework filled in", async () => {
    getQueue.mockResolvedValue(
      queue({
        rows: [
          kestrelRow({
            aiAction: "Hold",
            aiHomework: "Ask Kestrel which entity Ryan Chen trades under."
          })
        ]
      })
    );
    holdRow.mockResolvedValue(undefined);
    const element = await render();

    button(element, "hold").dispatchEvent(new CustomEvent("click"));
    await flush();
    const text = element.shadowRoot.querySelector(
      "lightning-textarea.hold-text"
    );
    expect(text.value).toBe("Ask Kestrel which entity Ryan Chen trades under.");
    text.value = "Ask Kestrel which entity, Inc. or Ltd.";
    text.dispatchEvent(
      new CustomEvent("change", {
        detail: { value: "Ask Kestrel which entity, Inc. or Ltd." }
      })
    );
    await flush();
    button(element, "hold-submit").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(holdRow).toHaveBeenCalledWith({
      rowId: "a0E000000000001AAA",
      homework: "Ask Kestrel which entity, Inc. or Ltd."
    });
    expect(element.shadowRoot.querySelector(".hold-dialog")).toBeNull();
    expect(getQueue).toHaveBeenCalledTimes(2);
  });

  it("cannot put a row on hold without saying what to find out", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render();
    button(element, "hold").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(button(element, "hold-submit").disabled).toBe(true);
  });

  it("shows held rows on their own tab, where they can be released", async () => {
    getQueue.mockResolvedValue(
      queue({
        rows: [],
        holdRows: [
          kestrelRow({
            onHold: true,
            holdReason: "Which Kestrel entity?",
            heldByName: "Dana Ops",
            heldSince: "2026-10-20T15:00:00.000Z",
            askedAt: "2026-10-21T15:00:00.000Z"
          })
        ]
      })
    );
    releaseHold.mockResolvedValue(undefined);
    const element = await render("hold");

    expect(element.shadowRoot.querySelectorAll("lightning-tab")[2].label).toBe(
      "On Hold (1)"
    );
    const items = table(element, "hold-table").items;
    expect(items[0].issueDetail).toBe("Which Kestrel entity?");
    expect(items[0].note).toContain("Asked");

    const box = element.shadowRoot.querySelector(".hold-box");
    expect(box.textContent).toContain("Dana Ops");
    expect(box.querySelector(".hold-homework").textContent).toBe(
      "Which Kestrel entity?"
    );
    expect(box.textContent).toContain("Asked");
    expect(button(element, "hold")).toBeNull();
    expect(button(element, "accept")).not.toBeNull();
    expect(button(element, "reject")).not.toBeNull();

    button(element, "release").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(releaseHold).toHaveBeenCalledWith({ rowId: "a0E000000000001AAA" });
  });

  it("lists what approving a roster row will do, and blocks what cannot be approved", async () => {
    const roster = kestrelRow({
      isRoster: true,
      rowType: "Roster",
      needsFirm: false,
      claudeAnswersIt: false,
      approvalPlan: [
        "Create advisor Priya Nair at Barder & Company - Oakville",
        "End Marcus Lee's assignment on 2026-09-30",
        "Assign code 2210 100% to Priya Nair from 2026-10-01"
      ],
      canApprove: true,
      isCodeIssue: true
    });
    getQueue.mockResolvedValue(queue({ rows: [roster], followUps: [] }));
    const element = await render("codes");

    const plan = [
      ...element.shadowRoot.querySelectorAll(".approval-plan li")
    ].map((li) => li.textContent);
    expect(plan).toHaveLength(3);
    expect(plan[1]).toBe("End Marcus Lee's assignment on 2026-09-30");
    expect(button(element, "accept").label).toBe("Approve roster entry");
    expect(button(element, "accept").disabled).toBe(false);

    getQueue.mockResolvedValue(
      queue({
        followUps: [],
        rows: [
          {
            ...roster,
            approvalPlan: [
              "Cannot approve: code 8800 is shared by a team. Update the team split by hand, then reject this row."
            ],
            canApprove: false
          }
        ]
      })
    );
    element.shadowRoot
      .querySelector("lightning-button-icon")
      .dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(button(element, "accept").disabled).toBe(true);
  });

  it("lists each firm on Email Firms with its questions, and emails it", async () => {
    getQueue.mockResolvedValue(
      queue({
        firmFollowUps: [
          {
            firmId: "001000000000009AAA",
            firmName: "Barder & Company",
            contactName: "Julia Morales",
            contactEmail: "julia.ops@example.com",
            questionCount: 2,
            notAskedCount: 2,
            questions: [
              {
                itemId: "a0E000000000002AAA",
                text: "Which fund is it?",
                source: "On hold · Unknown fund",
                askedAt: null
              },
              {
                itemId: "a0D000000000001AAA",
                text: "Who holds 3390?",
                source: "Code 3390 · Unknown Code",
                askedAt: "2026-10-22T15:00:00.000Z"
              }
            ]
          },
          {
            firmId: "001000000000008AAA",
            firmName: "Northgate Wealth Partners",
            contactEmail: null,
            questionCount: 1,
            notAskedCount: 1,
            questions: []
          }
        ]
      })
    );
    draftFirmEmail.mockResolvedValue({
      firmId: "001000000000009AAA",
      toAddress: "julia.ops@example.com",
      subject: "Two questions",
      htmlBody: "<p>Hello Julia,</p>",
      itemIds: ["a0E000000000002AAA", "a0D000000000001AAA"],
      draftedByClaude: true,
      note: "Drafted by Claude. Read it before sending."
    });
    encodeDefaultFieldValues.mockReturnValue("encoded");
    markAsked.mockResolvedValue(undefined);
    const element = await render("firms");

    expect(element.shadowRoot.querySelectorAll("lightning-tab")[3].label).toBe(
      "Email Firms (2)"
    );
    const firms = table(element, "firms-table").items;
    expect(firms.map((f) => f.title)).toEqual([
      "Barder & Company",
      "Northgate Wealth Partners"
    ]);
    expect(firms[0]).toMatchObject({
      subtitle: "Julia Morales · julia.ops@example.com",
      issueType: "2 not asked yet",
      lastText: "2 questions"
    });
    expect(firms[1].subtitle).toBe("No Operations Contact");

    const detail = element.shadowRoot.querySelector(".firm-detail");
    const questions = detail.querySelectorAll(".question-table tbody tr");
    expect(questions).toHaveLength(2);
    expect(
      [...questions[0].querySelectorAll("td")].map((td) => td.textContent)
    ).toEqual(["Which fund is it?", "On hold · Unknown fund", "Not asked yet"]);
    expect(questions[1].querySelectorAll("td")[2].textContent).toMatch(
      /^Asked Oct/
    );

    button(element, "email-firm").dispatchEvent(new CustomEvent("click"));
    await flush();

    expect(draftFirmEmail).toHaveBeenCalledWith({
      firmId: "001000000000009AAA"
    });
    expect(encodeDefaultFieldValues).toHaveBeenCalledWith({
      ToAddress: "julia.ops@example.com",
      Subject: "Two questions",
      HtmlBody: "<p>Hello Julia,</p>",
      RelatedToId: "001000000000009AAA"
    });
    expect(navigate).toHaveBeenCalledTimes(1);
    const nav = navigate.mock.calls[0][0];
    expect(nav.type).toBe("standard__quickAction");
    expect(nav.attributes.apiName).toBe("Global.SendEmail");
    expect(nav.state).toEqual({
      recordId: "001000000000009AAA",
      defaultFieldValues: "encoded"
    });
    expect(
      element.shadowRoot.querySelector(".pending-ask").textContent
    ).toContain("mark its 2 questions as asked");

    // The prompt belongs to Barder: it is not shown on another firm.
    await choose(element, "firms-table", "firm:001000000000008AAA");
    expect(element.shadowRoot.querySelector(".pending-ask")).toBeNull();
    expect(element.shadowRoot.querySelector(".no-contact")).not.toBeNull();
    expect(button(element, "email-firm").disabled).toBe(true);
    await choose(element, "firms-table", "firm:001000000000009AAA");

    button(element, "mark-asked").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(markAsked).toHaveBeenCalledWith({
      itemIds: ["a0E000000000002AAA", "a0D000000000001AAA"]
    });
    expect(element.shadowRoot.querySelector(".pending-ask")).toBeNull();
  });

  it("shows why an email could not be drafted", async () => {
    getQueue.mockResolvedValue(
      queue({
        firmFollowUps: [
          {
            firmId: "001000000000009AAA",
            firmName: "Barder & Company",
            contactName: "Julia Morales",
            contactEmail: "julia.ops@example.com",
            questionCount: 1,
            notAskedCount: 0,
            lastAskedAt: "2026-10-01T15:00:00.000Z",
            questions: []
          }
        ]
      })
    );
    draftFirmEmail.mockRejectedValue({
      body: { message: "Nothing is waiting for Barder & Company's answer." }
    });
    const element = await render("firms");
    const handler = jest.fn();
    element.addEventListener("lightning__showtoast", handler);

    expect(table(element, "firms-table").items[0].issueType).toContain(
      "send a reminder"
    );
    expect(button(element, "email-firm").label).toBe("Send a reminder");
    button(element, "email-firm").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(handler.mock.calls[0][0].detail.message).toBe(
      "Nothing is waiting for Barder & Company's answer."
    );
    expect(element.shadowRoot.querySelector(".pending-ask")).toBeNull();
  });

  it("shows no held note when nothing is held", async () => {
    getQueue.mockResolvedValue(queue({ followUps: [] }));
    const element = await render("codes");
    expect(element.shadowRoot.querySelector(".held-note")).toBeNull();
  });

  it("activates Claude's proposed mapping", async () => {
    const mapping = {
      batchId: "a0C000000000009AAA",
      batchName: "IB-000009",
      sourceFirm: "KESTREL",
      fileName: "kestrel_export.csv",
      profileId: "a0B000000000001AAA",
      profileName: "KESTREL - proposed by Claude",
      rationale: "Checks passed."
    };
    getQueue.mockResolvedValue(
      queue({ rows: [], followUps: [], mappings: [mapping] })
    );
    activateMapping.mockResolvedValue(undefined);
    const element = await render("mappings");

    expect(
      element.shadowRoot.querySelector(".mapping-detail .rationale").textContent
    ).toBe("Checks passed.");

    button(element, "activate").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(activateMapping).toHaveBeenCalledWith({
      profileId: "a0B000000000001AAA"
    });
  });

  it("uploads a file as base64 to a new dealer code", async () => {
    getQueue.mockResolvedValue(queue());
    uploadFile.mockResolvedValue({
      batchId: "a0C000000000002AAA",
      status: "Received",
      duplicate: false,
      message: "File received and queued for processing."
    });
    const element = await render();

    element.shadowRoot
      .querySelector("lightning-button.open-upload")
      .dispatchEvent(new CustomEvent("click"));
    await flush();
    element.shadowRoot
      .querySelector("lightning-combobox.upload-firm")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: "__other__" } })
      );
    await flush();
    element.shadowRoot
      .querySelector("lightning-input.upload-other-firm")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: " harbour-1 " } })
      );
    const input = element.shadowRoot.querySelector(
      "lightning-input.upload-file"
    );
    const file = new File(["Code,Advisor\n1001,Ryan Chen\n"], "harbour.csv", {
      type: "text/csv"
    });
    Object.defineProperty(input, "files", { value: [file] });
    input.dispatchEvent(new CustomEvent("change"));
    await flush();

    expect(button(element, "upload-submit").disabled).toBe(false);
    button(element, "upload-submit").dispatchEvent(new CustomEvent("click"));
    // FileReader finishes on a later tick.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    await new Promise((resolve) => setTimeout(resolve, 20));
    await flush();

    expect(uploadFile).toHaveBeenCalledWith({
      sourceFirm: "HARBOUR-1",
      fileName: "harbour.csv",
      base64Content: Buffer.from("Code,Advisor\n1001,Ryan Chen\n").toString(
        "base64"
      )
    });
    expect(element.shadowRoot.querySelector("section.slds-modal")).toBeNull();
  });

  it("refuses a file over 1 MB before uploading", async () => {
    getQueue.mockResolvedValue(queue());
    const element = await render();
    element.shadowRoot
      .querySelector("lightning-button.open-upload")
      .dispatchEvent(new CustomEvent("click"));
    await flush();
    element.shadowRoot
      .querySelector("lightning-combobox.upload-firm")
      .dispatchEvent(
        new CustomEvent("change", { detail: { value: "BARDER" } })
      );
    const input = element.shadowRoot.querySelector(
      "lightning-input.upload-file"
    );
    Object.defineProperty(input, "files", {
      value: [{ name: "big.csv", size: 1024 * 1024 + 1 }]
    });
    input.dispatchEvent(new CustomEvent("change"));
    await flush();

    expect(
      element.shadowRoot.querySelector(".upload-error").textContent
    ).toContain("larger than 1024 KB");
    button(element, "upload-submit").dispatchEvent(new CustomEvent("click"));
    await flush();
    expect(uploadFile).not.toHaveBeenCalled();
  });

  it("refreshes itself while background work runs, and stops when it is done", async () => {
    jest.useFakeTimers();
    getQueue.mockResolvedValueOnce(queue({ inFlight: 3 }));
    getQueue.mockResolvedValueOnce(queue({ inFlight: 1 }));
    getQueue.mockResolvedValue(queue({ inFlight: 0 }));
    const element = await render();
    expect(element.shadowRoot.querySelector(".working").textContent).toContain(
      "Working in the background (3)"
    );

    jest.advanceTimersByTime(POLL_MS);
    await flush();
    expect(getQueue).toHaveBeenCalledTimes(2);
    jest.advanceTimersByTime(POLL_MS);
    await flush();
    expect(getQueue).toHaveBeenCalledTimes(3);
    expect(element.shadowRoot.querySelector(".working")).toBeNull();

    jest.advanceTimersByTime(POLL_MS * 3);
    await flush();
    expect(getQueue).toHaveBeenCalledTimes(3);
  });

  it("stops refreshing after the time limit and says so", async () => {
    jest.useFakeTimers();
    getQueue.mockResolvedValue(queue({ inFlight: 2 }));
    const element = await render();
    for (let i = 0; i < MAX_POLLS; i++) {
      jest.advanceTimersByTime(POLL_MS);
      // eslint-disable-next-line no-await-in-loop
      await flush();
    }
    const calls = getQueue.mock.calls.length;
    jest.advanceTimersByTime(POLL_MS * 5);
    await flush();
    expect(getQueue.mock.calls.length).toBe(calls);
    expect(element.shadowRoot.querySelector(".working").textContent).toContain(
      "Click Refresh"
    );
  });

  it("shows a load error", async () => {
    getQueue.mockRejectedValue({ body: { message: "Insufficient access" } });
    const element = await render();
    expect(element.shadowRoot.querySelector(".load-error").textContent).toBe(
      "Insufficient access"
    );
  });
});

describe("helpers", () => {
  it("reads error messages from every shape", () => {
    expect(errorText({ body: { message: "A" } })).toBe("A");
    expect(errorText({ body: [{ message: "A" }, { message: "B" }] })).toBe(
      "A B"
    );
    expect(errorText(new Error("C"))).toBe("C");
    expect(errorText(undefined)).toBe("Something went wrong.");
    expect(errorText({})).toBe("Something went wrong.");
  });

  it("says when a question was asked and nudges after three days", () => {
    const now = new Date("2026-10-23T12:00:00.000Z").getTime();
    expect(askedText(null, now)).toBe("");
    expect(askedText("2026-10-22T12:00:00.000Z", now)).toMatch(/^Asked Oct/);
    expect(askedText("2026-10-22T12:00:00.000Z", now)).not.toContain(
      "reminder"
    );
    expect(askedText("2026-10-19T12:00:00.000Z", now)).toContain(
      "no answer after 4 days, send a reminder"
    );
  });

  it("words a bulk result by how many rows changed", () => {
    expect(bulkMessage(1, "One.", "{n} rows.")).toBe("One.");
    expect(bulkMessage(undefined, "One.", "{n} rows.")).toBe("One.");
    expect(bulkMessage(37, "One.", "{n} rows.")).toBe("37 rows.");
  });

  it("takes the base64 part of a data URL", () => {
    expect(base64Of("data:text/csv;base64,QUJD")).toBe("QUJD");
    expect(base64Of("data:;base64,")).toBe("");
    expect(base64Of(null)).toBe("");
  });
});
