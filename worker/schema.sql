CREATE TABLE IF NOT EXISTS users (
  id         TEXT PRIMARY KEY,
  email      TEXT UNIQUE NOT NULL,
  name       TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS email_codes (
  email        TEXT PRIMARY KEY,
  code_hash    TEXT NOT NULL,
  attempts     INTEGER NOT NULL DEFAULT 0,
  expires_at   TEXT NOT NULL,
  last_sent_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS households (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  invite_code TEXT UNIQUE NOT NULL,
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS household_members (
  id           TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   TEXT NOT NULL,
  UNIQUE(household_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_household_members_user     ON household_members(user_id);
CREATE INDEX IF NOT EXISTS idx_household_members_household ON household_members(household_id);

CREATE TABLE IF NOT EXISTS shopping_items (
  id           TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  product_id   TEXT REFERENCES products(id),
  name         TEXT NOT NULL,
  quantity     TEXT,
  notes        TEXT,
  category     TEXT NOT NULL DEFAULT 'Other',
  aisle_order  INTEGER NOT NULL DEFAULT 19,
  checked      INTEGER NOT NULL DEFAULT 0,
  added_by     TEXT NOT NULL REFERENCES users(id),
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_shopping_items_household ON shopping_items(household_id);

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

CREATE INDEX IF NOT EXISTS idx_purchase_history_product  ON purchase_history(product_id);
CREATE INDEX IF NOT EXISTS idx_purchase_history_household ON purchase_history(household_id);
