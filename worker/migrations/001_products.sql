-- Adds product deduplication and purchase history tracking

CREATE TABLE IF NOT EXISTS products (
  id           TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name         TEXT NOT NULL COLLATE NOCASE,
  category     TEXT NOT NULL DEFAULT 'Other',
  aisle_order  INTEGER NOT NULL DEFAULT 19,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  UNIQUE(household_id, name)
);

CREATE INDEX IF NOT EXISTS idx_products_household ON products(household_id);

CREATE TABLE IF NOT EXISTS purchase_history (
  id           TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  product_id   TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity     TEXT,
  purchased_by TEXT NOT NULL REFERENCES users(id),
  purchased_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_purchase_history_product   ON purchase_history(product_id);
CREATE INDEX IF NOT EXISTS idx_purchase_history_household ON purchase_history(household_id);

ALTER TABLE shopping_items ADD COLUMN product_id TEXT REFERENCES products(id);
