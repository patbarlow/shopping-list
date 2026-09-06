import assert from "node:assert/strict";
import { test } from "node:test";
import { itemCountMismatch, reconcileReceiptLines, totalsMismatch, type ReceiptLineItem } from "../src/receipt-lines.ts";

function line(
  description: string,
  total: number | null,
  extra: Partial<ReceiptLineItem> = {},
): ReceiptLineItem {
  return {
    description,
    quantity: 1,
    unit_price: total,
    total_price: total,
    size_value: null,
    size_unit: null,
    ...extra,
  };
}

// The real ALDI receipt this was built from: "Qty 2 @ $1.69 ea." sits under
// Milk Almond (2 x 1.69 = 3.38) and got stapled onto the Brie below it.
const aldi = (): ReceiptLineItem[] => [
  line("SteakCutChips750g", 2.79, { size_value: 750, size_unit: "g" }),
  line("Milk Almond UHT 1L", 3.38, { size_value: 1, size_unit: "L" }),
  line("Brie French 125g", 3.49, { quantity: 2, unit_price: 1.69, size_value: 125, size_unit: "g" }),
  line("Fetta Greek 200g", 2.89, { size_value: 200, size_unit: "g" }),
  line("FR Chk Breast CW", 12.04),
  line("P Mince 5 Str 500g", 6.99, { size_value: 500, size_unit: "g" }),
  line("Honey Raw Organic", 6.99),
];

test("moves a multi-buy onto the line above whose total it explains", () => {
  const out = reconcileReceiptLines(aldi());
  assert.deepEqual(
    out.map((i) => [i.description, i.quantity, i.unit_price]),
    [
      ["SteakCutChips750g", 1, 2.79],
      ["Milk Almond UHT 1L", 2, 1.69],
      ["Brie French 125g", 1, 3.49],
      ["Fetta Greek 200g", 1, 2.89],
      ["FR Chk Breast CW", 1, 12.04],
      ["P Mince 5 Str 500g", 1, 6.99],
      ["Honey Raw Organic", 1, 6.99],
    ],
  );
  assert.equal(out.some((i) => i.needs_review), false);
});

test("leaves a correctly attached multi-buy alone", () => {
  const items = [
    line("Chips", 2.79),
    line("Milk Almond UHT 1L", 3.38, { quantity: 2, unit_price: 1.69 }),
    line("Brie", 3.49),
  ];
  assert.deepEqual(reconcileReceiptLines(items), items);
});

test("leaves a by-weight line alone when its rate checks out", () => {
  const items = [line("Potato Sweet Gold", 3.97, { quantity: 1.017, unit_price: 3.9 })];
  assert.deepEqual(reconcileReceiptLines(items), items);
});

test("reassigns a by-weight line to the product it actually prices", () => {
  const out = reconcileReceiptLines([
    line("Potato Sweet Gold", 3.97),
    line("Brown Onions", 1.5, { quantity: 1.017, unit_price: 3.9 }),
  ]);
  assert.deepEqual(out.map((i) => [i.quantity, i.unit_price]), [[1.017, 3.9], [1, 1.5]]);
});

test("finds the owner below when the receipt prints the qty line above it", () => {
  const out = reconcileReceiptLines([
    line("Chips", 2.79, { quantity: 2, unit_price: 1.69 }),
    line("Milk Almond UHT 1L", 3.38),
  ]);
  assert.deepEqual(out.map((i) => [i.quantity, i.unit_price]), [[1, 2.79], [2, 1.69]]);
});

test("drops a multiplier no neighbouring line supports, and flags it", () => {
  const [item] = reconcileReceiptLines([line("Brie French 125g", 3.49, { quantity: 2, unit_price: 1.69 })]);
  assert.equal(item.quantity, null);
  assert.equal(item.unit_price, null);
  assert.equal(item.total_price, 3.49);
  assert.equal(item.needs_review, true);
});

test("does not steal a quantity from a neighbour that already has one", () => {
  const out = reconcileReceiptLines([
    line("Milk Almond UHT 1L", 3.38, { quantity: 2, unit_price: 1.69 }),
    line("Brie French 125g", 3.38, { quantity: 3, unit_price: 1.69 }),
  ]);
  assert.equal(out[0].quantity, 2);
  assert.equal(out[1].needs_review, true);
});

test("tolerates cent rounding in the printed unit price", () => {
  const items = [line("Yoghurt 3pk", 5.0, { quantity: 3, unit_price: 1.67 })];
  assert.deepEqual(reconcileReceiptLines(items), items);
});

test("leaves lines with no printed total untouched", () => {
  const items = [line("Mystery", null, { quantity: 2, unit_price: 1.69, total_price: null })];
  assert.deepEqual(reconcileReceiptLines(items), items);
});

test("item count counts units, not lines", () => {
  const reconciled = reconcileReceiptLines(aldi());
  assert.equal(itemCountMismatch(reconciled, 8), false); // 6 singles + one x2
  assert.equal(itemCountMismatch(reconciled, 7), true);
  assert.equal(itemCountMismatch(reconciled, null), false);
  // A weighed line is one item however many kilos it is.
  assert.equal(itemCountMismatch([line("Onions", 1.5, { quantity: 0.4, unit_price: 3.75 })], 1), false);
});

test("totals mismatch flags a receipt whose lines don't sum to the printed total", () => {
  const reconciled = reconcileReceiptLines(aldi());
  assert.equal(totalsMismatch(reconciled, 38.57), false);
  assert.equal(totalsMismatch(reconciled, 41.95), true);
  assert.equal(totalsMismatch(reconciled, null), false);
});
