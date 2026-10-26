import { LightningElement, api, wire } from "lwc";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";
import ROW_TABLE from "@salesforce/schema/Import_Staging_Row__c.AI_Field_Suggestions__c";
import ROW_HEADLINE from "@salesforce/schema/Import_Staging_Row__c.AI_Headline__c";
import ROW_ACTION from "@salesforce/schema/Import_Staging_Row__c.AI_Recommended_Action__c";
import ROW_HOMEWORK from "@salesforce/schema/Import_Staging_Row__c.AI_Homework__c";
import ROW_EXPLANATION from "@salesforce/schema/Import_Staging_Row__c.AI_Suggestion__c";
import ROW_CONFIDENCE from "@salesforce/schema/Import_Staging_Row__c.AI_Confidence__c";
import ROW_STATUS from "@salesforce/schema/Import_Staging_Row__c.AI_Status__c";
import CF_TABLE from "@salesforce/schema/Code_Follow_Up__c.AI_Field_Suggestions__c";
import CF_HOMEWORK from "@salesforce/schema/Code_Follow_Up__c.AI_Homework__c";
import CF_EXPLANATION from "@salesforce/schema/Code_Follow_Up__c.Suggested_Resolution__c";
import CF_CONFIDENCE from "@salesforce/schema/Code_Follow_Up__c.AI_Confidence__c";
import CF_STATUS from "@salesforce/schema/Code_Follow_Up__c.AI_Status__c";

const FIELDS = {
  Import_Staging_Row__c: {
    table: ROW_TABLE,
    headline: ROW_HEADLINE,
    action: ROW_ACTION,
    homework: ROW_HOMEWORK,
    explanation: ROW_EXPLANATION,
    confidence: ROW_CONFIDENCE,
    status: ROW_STATUS
  },
  Code_Follow_Up__c: {
    table: CF_TABLE,
    homework: CF_HOMEWORK,
    explanation: CF_EXPLANATION,
    confidence: CF_CONFIDENCE,
    status: CF_STATUS
  }
};
const CONFIDENCE_CLASS = {
  High: "slds-badge slds-theme_success",
  Medium: "slds-badge slds-theme_warning",
  Low: "slds-badge"
};
const ACTION_LABELS = {
  Accept: "Claude recommends: Accept",
  Reject: "Claude recommends: Reject",
  Hold: "Claude recommends: Put on hold"
};

/** Claude's per-field answer, stored as JSON. Anything malformed shows as no table rather than an error. */
export function parseFieldTable(json) {
  if (!json) {
    return [];
  }
  try {
    const lines = JSON.parse(json);
    if (!Array.isArray(lines)) {
      return [];
    }
    return lines
      .filter((l) => l && typeof l === "object")
      .map((l, i) => ({
        key: String(i),
        field: String(l.field || ""),
        value: l.value === null || l.value === undefined ? "" : String(l.value),
        confidence: String(l.confidence || ""),
        confidenceClass: CONFIDENCE_CLASS[l.confidence] || "slds-badge",
        reason: String(l.reason || "")
      }));
  } catch {
    return [];
  }
}

/**
 * Claude's suggestion on an Import Staging Row or Code Follow-Up record page, as a table:
 * Field, Suggestion, Confidence, Reason. Read only; decisions are made in Trade Review.
 */
export default class AiSuggestionTable extends LightningElement {
  @api recordId;
  @api objectApiName;
  record;
  error;

  get fieldSet() {
    return FIELDS[this.objectApiName];
  }

  get optionalFields() {
    const set = this.fieldSet;
    return set ? Object.values(set) : [];
  }

  @wire(getRecord, { recordId: "$recordId", optionalFields: "$optionalFields" })
  wiredRecord({ data, error }) {
    this.record = data;
    this.error = error;
  }

  value(key) {
    const set = this.fieldSet;
    return set && set[key] && this.record
      ? getFieldValue(this.record, set[key])
      : undefined;
  }

  get supported() {
    return !!this.fieldSet;
  }

  get lines() {
    return parseFieldTable(this.value("table"));
  }

  get hasLines() {
    return this.lines.length > 0;
  }

  get headline() {
    return this.value("headline");
  }

  get actionLabel() {
    return ACTION_LABELS[this.value("action")] || "";
  }

  get homework() {
    return this.value("homework");
  }

  get explanation() {
    return this.value("explanation");
  }

  get confidence() {
    return this.value("confidence");
  }

  get confidenceClass() {
    return CONFIDENCE_CLASS[this.confidence] || "slds-badge";
  }

  get hasAnswer() {
    return this.value("status") === "Suggested";
  }

  get stateText() {
    switch (this.value("status")) {
      case "No Suggestion":
        return "Claude had no suggestion for this record.";
      case "Invalid":
        return "Claude's answer broke the rules and was discarded. See the AI request log.";
      case "Failed":
        return "The request to Claude failed. See the AI request log.";
      default:
        return "Claude has not answered yet.";
    }
  }

  get errorText() {
    const e = this.error;
    if (!e) {
      return "";
    }
    return (e.body && e.body.message) || "The suggestion could not be loaded.";
  }
}
