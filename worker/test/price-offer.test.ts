import assert from "node:assert/strict";
import { test } from "node:test";
import { validateOffer } from "../src/price-offer.ts";
test("accepts a total multipack volume and discounted price", () => {
  const o = validateOffer({ name: "Red Bull", price: 9.83, size: 1000, unit: "mL" });
  assert.equal(o?.price, 9.83);
  assert.equal(o?.size, 1000);
  assert.equal(o?.question, null);
});
test("unknown or unsafe quantities require clarification", () => {
  for (const size of [null, 0, -1, Infinity, "1000"]) {
    const o = validateOffer({ name: "Red Bull", price: 9.83, size, unit: "mL" });
    assert.equal(o?.size, null);
    assert.ok(o?.question);
  }
  assert.equal(validateOffer({ name: "" }), null);
  assert.equal(validateOffer({ name: "Milk", price: 3, size: 2, unit: "L" })?.unit, null);
});
