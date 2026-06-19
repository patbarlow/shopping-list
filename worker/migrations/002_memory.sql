-- Adds price tracking, recipe import history, and receipt scanning support

ALTER TABLE purchase_history ADD COLUMN price_paid REAL;
ALTER TABLE purchase_history ADD COLUMN currency TEXT DEFAULT 'AUD';

CREATE TABLE IF NOT EXISTS recipes (
  id               TEXT PRIMARY KEY,
  household_id     TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  name             TEXT NOT NULL,
  source_url       TEXT,
  default_servings INTEGER,
  created_at       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS recipe_ingredients (
  id         TEXT PRIMARY KEY,
  recipe_id  TEXT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  product_id TEXT REFERENCES products(id),
  name       TEXT NOT NULL,
  quantity   TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS receipts (
  id           TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  scanned_at   TEXT NOT NULL,
  store_name   TEXT,
  total_amount REAL
);

CREATE INDEX IF NOT EXISTS idx_recipes_household     ON recipes(household_id);
CREATE INDEX IF NOT EXISTS idx_recipe_ingredients    ON recipe_ingredients(recipe_id);
CREATE INDEX IF NOT EXISTS idx_receipts_household    ON receipts(household_id);
