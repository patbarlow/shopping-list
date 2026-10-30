import assert from 'node:assert/strict';
import { test } from 'node:test';
import { receiptCandidates, resolveReceiptMatches } from '../src/price-history-match.ts';
const rows = [
  { product_id: 'energy', product_name: 'Energy drink', raw_description: 'REDBULL 4X250ML', purchase_history_id: 'red-1' },
  { product_id: 'energy', product_name: 'Energy drink', raw_description: 'REDBULL 4X250ML', purchase_history_id: 'red-2' },
  { product_id: 'energy', product_name: 'Energy drink', raw_description: 'V BLUE 4X250ML', purchase_history_id: 'v-1' },
  { product_id: 'energy', product_name: 'Energy drink', raw_description: 'RED BULL SUGARFREE', purchase_history_id: 'sf-1' },
];
test('generic list names retain individual brands and receipt variants', () => {
  const candidates = receiptCandidates(rows);
  assert.equal(candidates.length, 3);
  assert.deepEqual(resolveReceiptMatches(['r0', 'r0', 'invented-other-household'], candidates), [
    { productId: 'energy', purchaseIds: ['red-1', 'red-2'], receiptDescriptions: ['REDBULL 4X250ML'] },
  ]);
});
test('unknown and malformed match selections cannot inject history', () => {
  const candidates = receiptCandidates(rows);
  for (const keys of [null, 'r0', {}, ['unknown'], [7]]) assert.deepEqual(resolveReceiptMatches(keys, candidates), []);
});
