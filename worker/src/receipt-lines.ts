/**
 * Post-parse arithmetic checks on the line items an OCR pass produced.
 *
 * Multi-buy and weight lines ("Qty 2 @ $1.69 ea.", "1.017 kg NET @ $3.90/kg")
 * are printed on their own line under the product they belong to, and reading a
 * photographed receipt makes it easy to staple one onto the neighbouring product
 * instead — which silently halves (or doubles) that product's $/100g baseline,
 * since insights divide what was paid by the quantity.
 *
 * The receipt prints enough to check the model's work: for any line carrying a
 * quantity and a unit price, quantity x unit_price must come back to that line's
 * own total. When it doesn't, the pairing is wrong, and the correct owner is
 * almost always the line directly above (or, less often, below) — the one whose
 * printed total the multiplication actually explains.
 */

export interface ReceiptLineItem {
  description: string;
  quantity: number | null;
  unit_price: number | null;
  total_price: number | null;
  size_value: number | null;
  size_unit: string | null;
  /** Set when the arithmetic didn't add up and a human should eyeball the line. */
  needs_review?: boolean;
}

/** Receipts round to the cent, so allow a cent of slop (and 1% on big lines). */
function productMatches(quantity: number, unitPrice: number, total: number): boolean {
  return Math.abs(quantity * unitPrice - total) <= Math.max(0.015, Math.abs(total) * 0.01);
}

/** A line is "unmodified" if nothing multi-buy/by-weight has been attached to it yet. */
function hasNoMultiplier(item: ReceiptLineItem): boolean {
  return item.quantity == null || item.quantity === 1;
}

/**
 * Move a quantity/unit-price pair onto whichever neighbouring line its
 * arithmetic actually explains, and flag the ones that explain nothing.
 * Pure and order-preserving: it never adds, drops or reorders line items.
 */
export function reconcileReceiptLines(items: ReceiptLineItem[]): ReceiptLineItem[] {
  const out = items.map((i) => ({ ...i }));

  for (let i = 0; i < out.length; i++) {
    const item = out[i];
    const qty = item.quantity;
    const unitPrice = item.unit_price;

    // Only lines claiming a multiplier can be checked this way; a plain
    // single-unit line has nothing to get wrong.
    if (qty == null || unitPrice == null || qty === 1 || qty <= 0 || unitPrice <= 0) continue;
    // Without a printed total there is nothing to check the product against.
    if (item.total_price == null) continue;
    if (productMatches(qty, unitPrice, item.total_price)) continue;

    // The qty line prints below its product, so the line above is the usual
    // owner; check it first, then the line below for receipts that print above.
    const candidate = [i - 1, i + 1].find((j) => {
      const neighbour = out[j];
      return (
        neighbour != null &&
        neighbour.total_price != null &&
        hasNoMultiplier(neighbour) &&
        productMatches(qty, unitPrice, neighbour.total_price)
      );
    });

    if (candidate != null) {
      const owner = out[candidate];
      owner.quantity = qty;
      owner.unit_price = unitPrice;
      // This line keeps its own printed total as a plain single unit.
      item.quantity = 1;
      item.unit_price = item.total_price;
    } else {
      // Nothing on the receipt supports this multiplier. Storing it would
      // corrupt the unit-price baseline, so drop it and ask for a look.
      item.quantity = null;
      item.unit_price = null;
      item.needs_review = true;
    }
  }

  return out;
}

/** How many items above a discount row it applies to: "BUY 2 for $12.90" -> 2. */
function discountSpan(description: string): number {
  const match = /\b(?:buy|any|mix)\s+(\d+)\b/i.exec(description);
  const n = match ? Number(match[1]) : 1;
  return Number.isFinite(n) && n >= 1 && n <= 12 ? n : 1;
}

function roundCents(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * Fold a multi-buy discount row ("BUY 2 for $12.90  -4.60") into the items it
 * discounts, and drop the row. Woolworths prints these under the *pair* of
 * products they cover, so putting the whole reduction on the line above would
 * leave one product looking half price and the other full price; the money is
 * split across the covered items in proportion to what they cost.
 *
 * A discount that names no items above it is kept as-is and flagged, so a
 * receipt is never quietly reduced by money we couldn't attribute.
 */
export function foldDiscountLines(items: ReceiptLineItem[]): ReceiptLineItem[] {
  const out = items.map((i) => ({ ...i }));
  const kept = out.map(() => true);

  for (let i = 0; i < out.length; i++) {
    const discount = out[i];
    if (discount.total_price == null || discount.total_price >= 0) continue;

    // Walk back over the items this row covers, newest first.
    const targets: number[] = [];
    for (let j = i - 1; j >= 0 && targets.length < discountSpan(discount.description); j--) {
      const candidate = out[j];
      if (!kept[j] || candidate.total_price == null || candidate.total_price <= 0) continue;
      targets.unshift(j);
    }
    const covered = targets.reduce((sum, j) => sum + (out[j].total_price ?? 0), 0);
    if (targets.length === 0 || covered <= 0) {
      discount.needs_review = true;
      continue;
    }

    // Proportional split, with the rounding remainder landing on the last item.
    let remaining = discount.total_price;
    targets.forEach((j, index) => {
      const target = out[j];
      const share = index === targets.length - 1
        ? roundCents(remaining)
        : roundCents(discount.total_price! * ((target.total_price ?? 0) / covered));
      remaining = roundCents(remaining - share);
      target.total_price = roundCents((target.total_price ?? 0) + share);
      if (target.unit_price != null) {
        const per = target.quantity != null && target.quantity > 0 ? target.quantity : 1;
        target.unit_price = roundCents(target.total_price / per);
      }
    });
    kept[i] = false;
  }

  return out.filter((_, i) => kept[i]);
}

/**
 * The number of units a receipt's "N Items" footer should count for this line:
 * whole quantities are unit counts, fractional ones are a single weighed item.
 */
function unitsFor(item: ReceiptLineItem): number {
  const qty = item.quantity;
  if (qty == null || qty <= 0 || !Number.isInteger(qty)) return 1;
  return qty;
}

/**
 * True when the receipt's own printed item count disagrees with the quantities
 * we extracted — a missed (or invented) multi-buy line, which is exactly the
 * failure the per-line arithmetic can't see on its own.
 */
export function itemCountMismatch(items: ReceiptLineItem[], printedItemCount: number | null): boolean {
  if (printedItemCount == null || printedItemCount <= 0) return false;
  return items.reduce((sum, i) => sum + unitsFor(i), 0) !== printedItemCount;
}

/**
 * True when the line totals don't add up to the receipt's printed total — a
 * dropped, duplicated or misread line. Advisory only: unfolded discount rows
 * can trip it, so it flags for review rather than changing anything.
 */
export function totalsMismatch(items: ReceiptLineItem[], totalAmount: number | null): boolean {
  if (totalAmount == null || totalAmount <= 0) return false;
  if (items.some((i) => i.total_price == null)) return false;
  const sum = items.reduce((s, i) => s + (i.total_price ?? 0), 0);
  return Math.abs(sum - totalAmount) > 0.015;
}
