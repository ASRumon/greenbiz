-- Keep the whole sale arithmetic on the ledger row:
--   subtotal_minor  the catalogue bill
--   discount_minor  what the shopkeeper knocked off (in Taka)
--   amount_minor    what was actually collected / moved
--
-- A merged mobile-money row can differ from the sale total by the cash-out
-- charge, and a split payment books the cash half separately. Storing the bill
-- lets Payments show "Sale ৳250 · Bill ৳257 · ৳7 discount" without guessing.
ALTER TABLE `transactions`
ADD `subtotal_minor` integer NOT NULL DEFAULT 0;