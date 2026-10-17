-- How the money moved. Null on older rows (before payment capture) and on
-- imported transactions that predate the column.
ALTER TABLE `transactions`
ADD `payment_method` text;
CREATE INDEX `transactions_shop_method_idx` ON `transactions` (`shop_id`, `payment_method`);