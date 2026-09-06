import assert from "node:assert/strict";
import { test } from "node:test";
import { ReceiptAssembler, type ReceiptRecord } from "../src/receipt-stream.ts";

// The ALDI receipt as the model streams it: header, a line per product, totals.
const JSONL = [
  '{"type":"receipt","store_name":"ALDI STORES","receipt_date":"2026-09-06"}',
  '{"type":"item","description":"SteakCutChips750g","quantity":1,"unit_price":2.79,"total_price":2.79,"size_value":750,"size_unit":"g"}',
  '{"type":"item","description":"Milk Almond UHT 1L","quantity":2,"unit_price":1.69,"total_price":3.38,"size_value":1,"size_unit":"L"}',
  '{"type":"item","description":"Brie French 125g","quantity":1,"unit_price":3.49,"total_price":3.49,"size_value":125,"size_unit":"g"}',
  '{"type":"totals","total_amount":9.66,"item_count":4}',
].join("\n");

function feed(text: string, chunkSize: number): ReceiptRecord[] {
  const assembler = new ReceiptAssembler();
  const records: ReceiptRecord[] = [];
  for (let i = 0; i < text.length; i += chunkSize) {
    records.push(...assembler.push(text.slice(i, i + chunkSize)));
  }
  records.push(...assembler.finish());
  return records;
}

test("emits a record per line as it arrives", () => {
  const assembler = new ReceiptAssembler();
  const lines = JSONL.split("\n");

  assert.deepEqual(assembler.push(lines[0] + "\n"), [
    { type: "receipt", store_name: "ALDI STORES", receipt_date: "2026-09-06" },
  ]);
  // A product isn't emitted until its line is complete.
  assert.equal(assembler.push(lines[1].slice(0, 40)).length, 0);
  const rest = assembler.push(lines[1].slice(40) + "\n");
  assert.equal(rest.length, 1);
  assert.equal(rest[0].type, "item");
  assert.equal(assembler.lineItems.length, 1);
});

test("chunk boundaries don't change the result", () => {
  const whole = feed(JSONL, JSONL.length);
  for (const size of [1, 3, 17, 64, 500]) {
    assert.deepEqual(feed(JSONL, size), whole, `chunk size ${size}`);
  }
  assert.equal(whole.length, 5);
});

test("assembles the receipt from streamed records", () => {
  const assembler = new ReceiptAssembler();
  assembler.push(JSONL);
  assembler.finish();
  const built = assembler.build()!;
  assert.equal(built.header.store_name, "ALDI STORES");
  assert.equal(built.header.receipt_date, "2026-09-06");
  assert.deepEqual(built.totals, { total_amount: 9.66, item_count: 4 });
  assert.deepEqual(built.line_items.map((i) => i.description), [
    "SteakCutChips750g",
    "Milk Almond UHT 1L",
    "Brie French 125g",
  ]);
  assert.deepEqual(built.line_items[1], {
    description: "Milk Almond UHT 1L",
    quantity: 2,
    unit_price: 1.69,
    total_price: 3.38,
    size_value: 1,
    size_unit: "L",
  });
});

test("the last record needs no trailing newline", () => {
  const assembler = new ReceiptAssembler();
  assembler.push(JSONL); // ends mid-line, no "\n" after the totals record
  assert.equal(assembler.build()!.totals.total_amount, null);
  assert.equal(assembler.finish().length, 1);
  assert.equal(assembler.build()!.totals.total_amount, 9.66);
});

test("ignores code fences, blank lines and prose", () => {
  const assembler = new ReceiptAssembler();
  const records = assembler.push(
    "```json\n\nHere is the receipt:\n" +
      '{"type":"item","description":"Honey Raw Organic","quantity":1,"unit_price":6.99,"total_price":6.99,"size_value":null,"size_unit":null}\n' +
      "```\n",
  );
  assert.equal(records.length, 1);
  assert.equal(assembler.lineItems.length, 1);
});

test("takes an item line that omits its type", () => {
  const assembler = new ReceiptAssembler();
  const records = assembler.push('{"description":"Fetta Greek 200g","total_price":2.89}\n');
  assert.equal(records.length, 1);
  assert.deepEqual(assembler.lineItems[0], {
    description: "Fetta Greek 200g",
    quantity: null,
    unit_price: null,
    total_price: 2.89,
    size_value: null,
    size_unit: null,
  });
});

test("falls back to the single-object shape a model might return instead", () => {
  const assembler = new ReceiptAssembler();
  assembler.push(
    '{"store_name":"ALDI STORES","total_amount":9.66,"receipt_date":"2026-09-06","item_count":4,"line_items":[' +
      '{"description":"SteakCutChips750g","quantity":1,"unit_price":2.79,"total_price":2.79,"size_value":750,"size_unit":"g"},' +
      '{"description":"Milk Almond UHT 1L","quantity":2,"unit_price":1.69,"total_price":3.38,"size_value":1,"size_unit":"L"}]}',
  );
  assembler.finish();
  const built = assembler.build()!;
  assert.equal(built.header.store_name, "ALDI STORES");
  assert.deepEqual(built.totals, { total_amount: 9.66, item_count: 4 });
  assert.equal(built.line_items.length, 2);
});

test("a truncated stream keeps the products that did arrive", () => {
  const cut = JSONL.slice(0, JSONL.indexOf("Brie") + 10);
  const assembler = new ReceiptAssembler();
  assembler.push(cut);
  assembler.finish();
  const built = assembler.build()!;
  assert.equal(built.line_items.length, 2); // the half-written Brie line is dropped
  assert.equal(built.totals.total_amount, null); // and the totals never arrived
});

test("nothing usable builds to nothing", () => {
  const assembler = new ReceiptAssembler();
  assembler.push("I couldn't read that receipt, sorry.");
  assembler.finish();
  assert.equal(assembler.build(), null);
});
