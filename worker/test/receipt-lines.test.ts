import assert from "node:assert/strict";
import { test } from "node:test";
import {
  foldDiscountLines,
  itemCountMismatch,
  reconcileReceiptLines,
  totalsMismatch,
  type ReceiptLineItem,
} from "../src/receipt-lines.ts";

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

// Woolworths eReceipt shapes: multi-buy discount rows that cover the two
// products printed above them, and a "Qty 2" line carrying the money for a
// product line that printed no price of its own.
test("splits a BUY 2 discount across both items it covers", () => {
  const out = foldDiscountLines([
    line("Remedy Sodaly Yuzu Lemon 250ml 4pk", 8.75),
    line("Remedy Sodaly Blood Orange 250ml 4pk", 8.75),
    line("BUY 2 for $12.90", -4.6),
  ]);
  assert.equal(out.length, 2);
  assert.deepEqual(out.map((i) => i.total_price), [6.45, 6.45]);
  assert.deepEqual(out.map((i) => i.unit_price), [6.45, 6.45]);
});

test("splits an ANY 2 discount and leaves earlier items alone", () => {
  const out = foldDiscountLines([
    line("Nurofen Zavance Tablets 256mg 24pk", 9.0),
    line("Mfoods Coriander Leaves 5g", 3.5),
    line("Mfoods Dill Leaf Tips 10g", 3.5),
    line("ANY 2 for $6.00", -1.0),
  ]);
  assert.deepEqual(out.map((i) => i.total_price), [9.0, 3.0, 3.0]);
});

test("splits an uneven discount in proportion to price, to the cent", () => {
  const out = foldDiscountLines([
    line("Cheap thing", 4.0),
    line("Pricier thing", 8.0),
    line("BUY 2 for $9.00", -3.0),
  ]);
  assert.deepEqual(out.map((i) => i.total_price), [3.0, 6.0]);
  assert.equal(out.reduce((s, i) => s + (i.total_price ?? 0), 0), 9.0);
});

test("a single-item discount folds into the line above it", () => {
  const out = foldDiscountLines([line("Milo 460g", 7.5), line("Promotional Price", -1.5)]);
  assert.deepEqual(out.map((i) => [i.description, i.total_price]), [["Milo 460g", 6.0]]);
});

test("keeps and flags a discount with nothing above it to apply to", () => {
  const out = foldDiscountLines([line("BUY 2 for $12.90", -4.6), line("Remedy", 8.75)]);
  assert.equal(out.length, 2);
  assert.equal(out[0].needs_review, true);
});

test("keeps a folded multi-buy consistent with the receipt total", () => {
  const items = [
    line("Lurpak Spreadable 250g", 10.4, { quantity: 2, unit_price: 5.2, size_value: 250, size_unit: "g" }),
    line("Remedy Yuzu 4pk", 8.75),
    line("Remedy Blood Orange 4pk", 8.75),
    line("BUY 2 for $12.90", -4.6),
  ];
  const out = foldDiscountLines(reconcileReceiptLines(items));
  assert.deepEqual(out.map((i) => i.quantity), [2, 1, 1]);
  assert.equal(totalsMismatch(out, 23.3), false);
  assert.equal(itemCountMismatch(out, 4), false); // the x2 counts twice, the discount row not at all
});

test("folding runs after reconciling, so a discounted multi-buy keeps its quantity", () => {
  // The "Qty 2 @ $2.50 each" landed on the wrong line, and a discount follows.
  const out = foldDiscountLines(
    reconcileReceiptLines([
      line("Arnotts Scotch Finger 250g", 5.0),
      line("Fantastic Rice Crackers 100g", 1.85, { quantity: 2, unit_price: 2.5 }),
      line("Promotional Price", -0.85),
    ]),
  );
  assert.deepEqual(out.map((i) => [i.description, i.quantity, i.total_price]), [
    ["Arnotts Scotch Finger 250g", 2, 5.0],
    ["Fantastic Rice Crackers 100g", 1, 1.0],
  ]);
});

// The whole Woolworths eReceipt (06 Sep 2026, Marrickville Metro) as a model
// might return it with the two mistakes this file guards against: the "Qty 2 @
// $5.20 each" stapled onto the product below Lurpak, and both multi-buy
// discount rows left standing as their own line items.
test("recovers a full Woolworths eReceipt from a plausible mis-parse", () => {
  const scanned: ReceiptLineItem[] = [
    line("WW Canola Oil 2L", 6.0, { size_value: 2, size_unit: "L" }),
    line("Dairy Farmers Full Cream Milk 2L", 4.7, { size_value: 2, size_unit: "L" }),
    line("Nice Rice Sushi Rice 1kg", 5.4, { size_value: 1, size_unit: "kg" }),
    line("Thankyou BW Mint & Spring Flowers 1L", 8.95, { size_value: 1, size_unit: "L" }),
    line("Essentials Self Raising Flour 1kg", 1.3, { size_value: 1, size_unit: "kg" }),
    line("WW Chicken Stock 1L", 2.0, { size_value: 1, size_unit: "L" }),
    line("Nudie Orange Juice Pulp Free 1L", 6.5, { size_value: 1, size_unit: "L" }),
    line("Nice Rice Jasmine Rice 1kg", 4.5, { size_value: 1, size_unit: "kg" }),
    line("Lurpak Spreadable Slightly Salted 250g", 10.4, { size_value: 250, size_unit: "g" }),
    // Wrong: this multi-buy belongs to the Lurpak line above (2 x 5.20 = 10.40).
    line("Mainland Cheese Block Tasty 500g", 11.8, { quantity: 2, unit_price: 5.2, size_value: 500, size_unit: "g" }),
    line("WW Natural Greek Style Yoghurt 1kg", 4.2, { size_value: 1, size_unit: "kg" }),
    line("TTN Conditioner Hydrate & Nourish 500ml", 9.0, { size_value: 500, size_unit: "mL" }),
    line("TTN Hydrate & Nourish Shampoo 500ml", 9.0, { size_value: 500, size_unit: "mL" }),
    line("Obento Japanese Sushi Seasoning 250ml", 3.6, { size_value: 250, size_unit: "mL" }),
    line("Barilla Pasta Risoni N 26 500g", 3.5, { size_value: 500, size_unit: "g" }),
    line("Remedy Sodaly Yuzu Lemon 250ml 4pk", 8.75, { size_value: 1000, size_unit: "mL" }),
    line("Remedy Sodaly Blood Orange 250ml 4pk", 8.75, { size_value: 1000, size_unit: "mL" }),
    line("BUY 2 for $12.90", -4.6), // wrong: should have been folded into the two above
    line("Nestle Milo Drinking Powder 460g", 7.5, { size_value: 460, size_unit: "g" }),
    line("Weet-Bix Cereal 575g", 5.0, { size_value: 575, size_unit: "g" }),
    line("Manning Valley Free Range Eggs 12pk 700g", 8.7, { size_value: 700, size_unit: "g" }),
    line("S&B Wasabi Paste 43g", 3.3, { size_value: 43, size_unit: "g" }),
    line("Arnotts Biscuits Scotch Finger 250g", 5.0, { quantity: 2, unit_price: 2.5, size_value: 250, size_unit: "g" }),
    line("Fantastic Rice Crackers Original 100g", 1.85, { size_value: 100, size_unit: "g" }),
    line("Nurofen Zavance Tablets 256mg 24pk", 9.0),
    line("Mfoods Coriander Leaves 5g", 3.5, { size_value: 5, size_unit: "g" }),
    line("Mfoods Dill Leaf Tips 10g", 3.5, { size_value: 10, size_unit: "g" }),
    line("ANY 2 for $6.00", -1.0), // wrong: should have been folded into the two herbs
    line("RRD Potato Chips Honey Soy Chicken 165g", 6.0, { size_value: 165, size_unit: "g" }),
    line("Obento Japanese Yaki Nori For Sushi 25g", 4.0, { size_value: 25, size_unit: "g" }),
  ];

  const out = foldDiscountLines(reconcileReceiptLines(scanned));

  // Discount rows are gone, folded into the products they covered.
  assert.equal(out.length, 28);
  assert.equal(out.some((i) => (i.total_price ?? 0) < 0), false);
  assert.deepEqual(
    out.filter((i) => i.description.startsWith("Remedy")).map((i) => i.total_price),
    [6.45, 6.45],
  );
  assert.deepEqual(
    out.filter((i) => i.description.startsWith("Mfoods")).map((i) => i.total_price),
    [3.0, 3.0],
  );

  // The multi-buy is back on the Lurpak, and the cheese is a single unit again.
  const lurpak = out.find((i) => i.description.startsWith("Lurpak"))!;
  const cheese = out.find((i) => i.description.startsWith("Mainland"))!;
  assert.deepEqual([lurpak.quantity, lurpak.unit_price, lurpak.total_price], [2, 5.2, 10.4]);
  assert.deepEqual([cheese.quantity, cheese.total_price], [1, 11.8]);

  // And the receipt reconciles: 30 units, $160.10 of goods (before the $10
  // rewards redemption that made the card charge $150.10).
  assert.equal(itemCountMismatch(out, 30), false);
  assert.equal(totalsMismatch(out, 160.1), false);
  assert.equal(totalsMismatch(out, 150.1), true);
  assert.equal(out.some((i) => i.needs_review), false);
});
