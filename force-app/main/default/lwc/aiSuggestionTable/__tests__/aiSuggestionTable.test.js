import { createElement } from "lwc";
import AiSuggestionTable, { parseFieldTable } from "c/aiSuggestionTable";
import { getRecord } from "lightning/uiRecordApi";

function record(fields) {
  const out = {};
  Object.keys(fields).forEach((k) => {
    out[k] = { value: fields[k], displayValue: null };
  });
  return {
    apiName: "Import_Staging_Row__c",
    id: "a0E000000000001AAA",
    fields: out
  };
}

async function flush() {
  for (let i = 0; i < 3; i++) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

async function render(objectApiName) {
  const element = createElement("c-ai-suggestion-table", {
    is: AiSuggestionTable
  });
  element.recordId = "a0E000000000001AAA";
  element.objectApiName = objectApiName;
  document.body.appendChild(element);
  await flush();
  return element;
}

const TABLE = JSON.stringify([
  {
    field: "Advisor",
    value: "Priya Nair",
    confidence: "High",
    reason: "The roster row is the dealer's own record."
  },
  { field: "Firm", value: "Barder & Company", confidence: "Medium", reason: "" }
]);

describe("c-ai-suggestion-table", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows Claude's answer for each field as a table", async () => {
    const element = await render("Import_Staging_Row__c");
    getRecord.emit(
      record({
        AI_Status__c: "Suggested",
        AI_Field_Suggestions__c: TABLE,
        AI_Headline__c: "Priya Nair · takes over 2210 from Marcus Lee",
        AI_Recommended_Action__c: "Accept",
        AI_Suggestion__c: "Approve: the roster names Priya Nair from Oct 1.",
        AI_Confidence__c: "High"
      })
    );
    await flush();

    const root = element.shadowRoot;
    expect(root.querySelector(".headline").textContent.trim()).toBe(
      "Priya Nair · takes over 2210 from Marcus Lee"
    );
    expect(root.querySelector(".ai-action").textContent).toContain(
      "Claude recommends: Accept"
    );
    const rows = root.querySelectorAll(".field-table tbody tr");
    expect(rows).toHaveLength(2);
    expect(
      [...rows[0].querySelectorAll("td")].map((td) => td.textContent)
    ).toEqual([
      "Advisor",
      "Priya Nair",
      "High",
      "The roster row is the dealer's own record."
    ]);
    expect(root.querySelector(".explanation").textContent).toContain(
      "Priya Nair from Oct 1"
    );
  });

  it("labels the reasoning and the question for the firm, and marks a field Claude left open", async () => {
    const element = await render("Code_Follow_Up__c");
    getRecord.emit(
      record({
        AI_Status__c: "Suggested",
        AI_Field_Suggestions__c:
          '[{"field":"Advisor","value":null,"confidence":"Low","reason":"Nothing names either member."}]',
        Suggested_Resolution__c: "The code is split between two advisors.",
        AI_Homework__c: "Which advisor placed the trade?",
        AI_Confidence__c: "Low"
      })
    );
    await flush();

    const root = element.shadowRoot;
    const headings = [...root.querySelectorAll("h3")].map((h) =>
      h.textContent.trim()
    );
    expect(headings).toEqual(["Why", "Question for the firm"]);
    expect(root.querySelector(".homework").textContent).toBe(
      "Which advisor placed the trade?"
    );
    const value = root.querySelector(".field-table tbody td:nth-child(2)");
    expect(value.textContent).toBe("No single answer");
    expect(value.className).toContain("open-question");
  });

  it("says when Claude has not answered", async () => {
    const element = await render("Code_Follow_Up__c");
    getRecord.emit(record({ AI_Status__c: "Failed" }));
    await flush();
    expect(element.shadowRoot.querySelector(".state").textContent).toContain(
      "The request to Claude failed"
    );
    expect(element.shadowRoot.querySelector(".field-table")).toBeNull();
  });

  it("asks to be placed on a supported page", async () => {
    const element = await render("Account");
    expect(element.shadowRoot.querySelector(".unsupported")).not.toBeNull();
  });

  it("shows a load error", async () => {
    const element = await render("Import_Staging_Row__c");
    getRecord.error({ message: "No access" });
    await flush();
    expect(element.shadowRoot.querySelector(".load-error")).not.toBeNull();
  });
});

describe("parseFieldTable", () => {
  it("reads Claude's JSON and ignores anything malformed", () => {
    expect(parseFieldTable(TABLE)).toHaveLength(2);
    expect(parseFieldTable(TABLE)[1].confidenceClass).toContain(
      "slds-theme_warning"
    );
    expect(parseFieldTable("not json")).toEqual([]);
    expect(parseFieldTable('{"field":"Firm"}')).toEqual([]);
    expect(parseFieldTable(null)).toEqual([]);
    expect(
      parseFieldTable('[null, {"field":"Fund","value":12}]')[0].value
    ).toBe("12");
  });
});
