-- Package size per receipt line, so purchases can be compared on a $/100g or $/100mL baseline
-- regardless of which size variant was bought.

ALTER TABLE receipt_line_items ADD COLUMN size_value REAL;
ALTER TABLE receipt_line_items ADD COLUMN size_unit TEXT;
