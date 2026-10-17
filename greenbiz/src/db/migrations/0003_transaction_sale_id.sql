-- Idempotency key for a sale, separate from the transaction primary key.
--
-- A sale that is paid by an SMS confirmation merges into that existing
-- transaction, so its id is not the client-generated sale id. Without this
-- column a retry after a lost response would decrement stock twice.
ALTER TABLE `transactions`
ADD `sale_id` text;
CREATE UNIQUE INDEX `transactions_sale_id_unique_idx` ON `transactions` (`sale_id`);