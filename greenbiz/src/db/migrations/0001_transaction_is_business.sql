-- Mark whether a transaction belongs to the business.
--
-- Existing rows are business transactions (the app only recorded business money
-- before this change), so DEFAULT 1 preserves every score and total.
ALTER TABLE `transactions`
ADD `is_business` integer DEFAULT 1 NOT NULL;