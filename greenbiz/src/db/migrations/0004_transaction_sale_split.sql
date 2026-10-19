-- A split payment books two ledger rows against one sale: the mobile-money
-- confirmation (already in `transactions`) and the cash the customer handed
-- over. Both carry the same client sale id, so the index can no longer be
-- unique.
--
-- Idempotency is still enforced in `POST /shops/:shopId/sales`: before doing
-- any work it looks up every row with this sale id and returns the existing
-- receipt on a retry.
DROP INDEX IF EXISTS `transactions_sale_id_unique_idx`;
CREATE INDEX `transactions_sale_id_idx` ON `transactions` (`sale_id`);