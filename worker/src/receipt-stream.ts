/**
 * Incremental assembly of a receipt from the model's newline-delimited output.
 *
 * The scanner shows each product the moment it is read, printing the receipt
 * onto the screen as it arrives rather than after the whole round trip — so the
 * parse has to hand back finished records mid-response. One JSON object per
 * line makes that trivial: every newline is a complete, parsable record.
 *
 * The finished receipt is assembled from the same records, so the streaming and
 * one-shot paths produce identical output and share every downstream check.
 */

import type { ReceiptLineItem } from "./receipt-lines";

export interface ReceiptHeader {
  store_name: string | null;
  receipt_date: string | null;
}

export interface ReceiptTotals {
  total_amount: number | null;
  item_count: number | null;
}

export type ReceiptRecord =
  | ({ type: "receipt" } & ReceiptHeader)
  | { type: "item"; item: ReceiptLineItem }
  | ({ type: "totals" } & ReceiptTotals);

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function str(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** Turn one parsed JSON object into a record, or null if it isn't one we know. */
function toRecord(raw: unknown): ReceiptRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;

  if (o.type === "receipt") {
    return { type: "receipt", store_name: str(o.store_name), receipt_date: str(o.receipt_date) };
  }
  if (o.type === "totals") {
    return { type: "totals", total_amount: num(o.total_amount), item_count: num(o.item_count) };
  }
  // An item line is anything carrying a description — the "type" is optional so
  // a model that omits it on the repetitive lines still parses.
  const description = str(o.description);
  if (!description) return null;
  return {
    type: "item",
    item: {
      description,
      quantity: num(o.quantity),
      unit_price: num(o.unit_price),
      total_price: num(o.total_price),
      size_value: num(o.size_value),
      size_unit: str(o.size_unit),
    },
  };
}

/** Strip the code fence a model sometimes wraps its output in. */
function isNoise(line: string): boolean {
  const trimmed = line.trim();
  return trimmed === "" || trimmed.startsWith("```") || trimmed === "[" || trimmed === "]";
}

/**
 * Feed model output in as it arrives; take back the records each chunk completed.
 * Chunk boundaries don't matter — a record is emitted once its line is whole.
 */
export class ReceiptAssembler {
  private buffer = "";
  private header: ReceiptHeader = { store_name: null, receipt_date: null };
  private totals: ReceiptTotals = { total_amount: null, item_count: null };
  private items: ReceiptLineItem[] = [];
  /** Everything seen, kept only for the whole-object fallback parse. */
  private text = "";

  push(chunk: string): ReceiptRecord[] {
    this.text += chunk;
    this.buffer += chunk;
    const lines = this.buffer.split("\n");
    // The last piece may be a partial line — hold it for the next chunk.
    this.buffer = lines.pop() ?? "";
    return lines.flatMap((line) => this.consume(line));
  }

  /** Flush the trailing line (the model's last record has no newline after it). */
  finish(): ReceiptRecord[] {
    const trailing = this.buffer;
    this.buffer = "";
    return trailing ? this.consume(trailing) : [];
  }

  private consume(line: string): ReceiptRecord[] {
    if (isNoise(line)) return [];
    let parsed: unknown;
    try {
      parsed = JSON.parse(line.trim().replace(/,$/, ""));
    } catch {
      return []; // Prose, a stray fence, a truncated line: ignore it.
    }
    const record = toRecord(parsed);
    if (!record) return [];
    if (record.type === "receipt") {
      this.header = { store_name: record.store_name, receipt_date: record.receipt_date };
    } else if (record.type === "totals") {
      this.totals = { total_amount: record.total_amount, item_count: record.item_count };
    } else {
      this.items.push(record.item);
    }
    return [record];
  }

  get lineItems(): ReceiptLineItem[] {
    return this.items;
  }

  /**
   * The receipt as assembled. Falls back to the single-object shape if the model
   * ignored the line-per-record format and returned one JSON blob after all.
   */
  build(): { header: ReceiptHeader; totals: ReceiptTotals; line_items: ReceiptLineItem[] } | null {
    if (this.items.length > 0) {
      return { header: this.header, totals: this.totals, line_items: this.items };
    }
    return parseWholeObject(this.text);
  }
}

/** The pre-JSONL output shape, kept as a fallback for a model that reverts to it. */
function parseWholeObject(
  text: string,
): { header: ReceiptHeader; totals: ReceiptTotals; line_items: ReceiptLineItem[] } | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) return null;
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text.slice(start, end + 1)) as Record<string, unknown>;
  } catch {
    return null;
  }
  const rawItems = parsed.line_items;
  if (!Array.isArray(rawItems)) return null;
  const line_items = rawItems
    .map((raw) => toRecord(raw))
    .filter((r): r is { type: "item"; item: ReceiptLineItem } => r?.type === "item")
    .map((r) => r.item);
  if (line_items.length === 0) return null;
  return {
    header: { store_name: str(parsed.store_name), receipt_date: str(parsed.receipt_date) },
    totals: { total_amount: num(parsed.total_amount), item_count: num(parsed.item_count) },
    line_items,
  };
}
