-- Adds receipt line item persistence, product alias learning, and unplanned purchase tracking

CREATE TABLE IF NOT EXISTS product_aliases (
  id               TEXT PRIMARY KEY,
  household_id     TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  raw_description  TEXT NOT NULL,
  product_id       TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  match_count      INTEGER NOT NULL DEFAULT 1,
  last_seen_at     TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  UNIQUE(household_id, raw_description)
);

CREATE INDEX IF NOT EXISTS idx_aliases_household ON product_aliases(household_id);
CREATE INDEX IF NOT EXISTS idx_aliases_product   ON product_aliases(product_id);

CREATE TABLE IF NOT EXISTS receipt_line_items (
  id                  TEXT PRIMARY KEY,
  receipt_id          TEXT NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
  household_id        TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  raw_description     TEXT NOT NULL,
  quantity            REAL,
  unit_price          REAL,
  total_price         REAL,
  product_id          TEXT REFERENCES products(id),
  match_source        TEXT,
  confirmed           INTEGER NOT NULL DEFAULT 0,
  purchase_history_id TEXT REFERENCES purchase_history(id),
  created_at          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rli_receipt   ON receipt_line_items(receipt_id);
CREATE INDEX IF NOT EXISTS idx_rli_household ON receipt_line_items(household_id);
CREATE INDEX IF NOT EXISTS idx_rli_product   ON receipt_line_items(product_id);

ALTER TABLE receipts ADD COLUMN receipt_date TEXT;
ALTER TABLE receipts ADD COLUMN currency TEXT DEFAULT 'AUD';

ALTER TABLE purchase_history ADD COLUMN source TEXT DEFAULT 'manual';
