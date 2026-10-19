-- Shops round bills down ("৳257, give me ৳250") or give a regular a small
-- discount. The transaction amount is what was actually collected; this column
-- keeps the difference from the list-price bill so discounts stay visible in
-- reports instead of only in the customer's memory.
ALTER TABLE `transactions`
ADD `discount_minor` integer NOT NULL DEFAULT 0;