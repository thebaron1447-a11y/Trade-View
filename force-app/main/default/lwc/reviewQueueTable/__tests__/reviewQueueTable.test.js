import { createElement } from "lwc";
import ReviewQueueTable from "c/reviewQueueTable";

const ITEMS = [
  {
    key: "fu:1",
    title: "Code 5521",
    subtitle: "Northgate Wealth Partners",
    note: "Asked Oct 20",
    issueType: "Code Dormant",
    issueDetail: "",
    badges: [{ key: "c", label: "Claude: Medium", cls: "slds-badge" }],
    lastText: "1 · $25,000.00",
    groupLabel: "Codes to fix"
  },
  {
    key: "row:2",
    title: "Priya Nair · Rep code mismatch on 2210",
    subtitle: "BARDER · row 2",
    note: "",
    issueType: "New code holder",
    issueDetail: "+1 more",
    badges: [],
    lastText: "Roster",
    groupLabel: "Roster and code decisions"
  }
];

async function render(props) {
  const element = createElement("c-review-queue-table", {
    is: ReviewQueueTable
  });
  Object.assign(element, props);
  document.body.appendChild(element);
  await Promise.resolve();
  return element;
}

describe("c-review-queue-table", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("shows each item with its group, issue type, Claude's view and amount", async () => {
    const element = await render({
      items: ITEMS,
      selectedKey: "row:2",
      firstLabel: "Code or row",
      lastLabel: "Held or amount"
    });
    const root = element.shadowRoot;
    expect(
      [...root.querySelectorAll("thead th")].map((t) => t.textContent)
    ).toEqual(["Code or row", "Issue type", "Held or amount"]);
    expect(
      [...root.querySelectorAll(".group-label")].map((g) =>
        g.textContent.trim()
      )
    ).toEqual(["Codes to fix", "Roster and code decisions"]);
    const rows = root.querySelectorAll("tr.queue-row");
    expect(rows).toHaveLength(2);
    expect(rows[0].querySelector(".item-title").textContent).toBe("Code 5521");
    expect(rows[0].querySelector(".item-note").textContent).toBe(
      "Asked Oct 20"
    );
    expect(rows[0].querySelector(".badges").textContent).toBe("Claude: Medium");
    expect(rows[0].querySelector(".last-cell").textContent).toBe(
      "1 · $25,000.00"
    );
    expect(rows[1].querySelector(".issue-detail").textContent).toBe("+1 more");
    expect(rows[1].className).toContain("queue-row_selected");
    expect(rows[0].className).not.toContain("queue-row_selected");
  });

  it("says which item was clicked", async () => {
    const element = await render({ items: ITEMS });
    const handler = jest.fn();
    element.addEventListener("select", handler);
    element.shadowRoot.querySelectorAll(".queue-button")[1].click();
    expect(handler.mock.calls[0][0].detail).toEqual({ key: "row:2" });
  });

  it("shows the empty text when there is nothing", async () => {
    const element = await render({
      items: [],
      emptyText: "Nothing needs a decision."
    });
    expect(element.shadowRoot.querySelector("table")).toBeNull();
    expect(
      element.shadowRoot.querySelector(".empty-text").textContent.trim()
    ).toBe("Nothing needs a decision.");
  });
});
