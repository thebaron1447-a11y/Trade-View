import { LightningElement, api } from "lwc";

/**
 * The work-queue table used by every Trade Review tab: one row per item with three columns
 * (the item, its issue type and an amount or count). Items can start a group (a header row).
 * Fires "select" with detail { key } when an item is clicked.
 */
export default class ReviewQueueTable extends LightningElement {
  @api items = [];
  @api selectedKey;
  @api firstLabel = "Item";
  @api typeLabel = "Issue type";
  @api lastLabel = "Amount";
  @api emptyText = "Nothing here.";

  get hasItems() {
    return !!(this.items && this.items.length);
  }

  get rows() {
    return (this.items || []).map((item) => ({
      ...item,
      rowClass:
        item.key === this.selectedKey
          ? "queue-row queue-row_selected"
          : "queue-row",
      groupKey: "g-" + item.key,
      hasBadges: !!(item.badges && item.badges.length)
    }));
  }

  handleSelect(event) {
    this.dispatchEvent(
      new CustomEvent("select", {
        detail: { key: event.currentTarget.dataset.key }
      })
    );
  }
}
