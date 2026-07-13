-- How often the household does a big shop, so the forecast horizon can match
-- reality instead of assuming a weekly shop.
-- One of: twice_weekly, weekly, biweekly, twice_monthly, monthly.

ALTER TABLE households ADD COLUMN shopping_frequency TEXT NOT NULL DEFAULT 'weekly';
