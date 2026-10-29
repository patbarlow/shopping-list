export interface ReceiptIdentity {
  product_id: string;
  raw_description: string;
  purchase_history_id: string | null;
}
export interface ReceiptCandidate {
  key: string;
  productId: string;
  productName: string;
  description: string;
  purchaseIds: string[];
}

// Keep the receipt identity separate from the household's simplified list name.
export function receiptCandidates(rows: (ReceiptIdentity & { product_name: string })[]): ReceiptCandidate[] {
  const grouped = new Map<string, ReceiptCandidate>();
  for (const row of rows) {
    if (!row.purchase_history_id) continue;
    const identity = JSON.stringify([row.product_id, row.raw_description]);
    let candidate = grouped.get(identity);
    if (!candidate) {
      candidate = { key: `r${grouped.size}`, productId: row.product_id, productName: row.product_name,
        description: row.raw_description, purchaseIds: [] };
      grouped.set(identity, candidate);
    }
    if (!candidate.purchaseIds.includes(row.purchase_history_id)) candidate.purchaseIds.push(row.purchase_history_id);
  }
  return [...grouped.values()];
}

// Model output is only a selection of identities already fetched for this
// authenticated household. It cannot supply prices, IDs or purchase records.
export function resolveReceiptMatches(rawKeys: unknown, candidates: ReceiptCandidate[]) {
  const keys = new Set(Array.isArray(rawKeys) ? rawKeys.filter((x): x is string => typeof x === 'string') : []);
  const matches = new Map<string, { productId: string; purchaseIds: string[]; receiptDescriptions: string[] }>();
  for (const candidate of candidates) {
    if (!keys.has(candidate.key)) continue;
    const match = matches.get(candidate.productId) ?? { productId: candidate.productId, purchaseIds: [], receiptDescriptions: [] };
    match.purchaseIds.push(...candidate.purchaseIds);
    match.receiptDescriptions.push(candidate.description);
    matches.set(candidate.productId, match);
  }
  return [...matches.values()].map(m => ({ ...m, purchaseIds: [...new Set(m.purchaseIds)] }));
}
