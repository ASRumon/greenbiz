/**
 * How far a mobile-money payment may sit from the sale total and still be the
 * same payment.
 *
 * Cash-out charges on bKash/Nagad/Rocket/UPI run about 10-20 taka per thousand
 * (1-2%). A customer paying by mobile money usually adds that charge to what
 * they send, and sometimes the shop absorbs it instead, so the confirmation SMS
 * is a few taka away from the bill either way.
 *
 * Anything inside this band is treated as the payment for the sale: the sale is
 * merged into the existing SMS row instead of booking a second inflow. The
 * Flutter app applies the same rule in `lib/core/payment_tolerance.dart`, so the
 * two sides agree on which message belongs to which sale.
 */

/** The low end of the cash-out charge: 10 taka per thousand. */
export const CASH_OUT_PER_THOUSAND_MIN = 10;

/** The high end of the cash-out charge: 20 taka per thousand. */
export const CASH_OUT_PER_THOUSAND_MAX = 20;

/**
 * Floor for very small bills: below ~50 taka, 2% rounds to nothing, yet the
 * charge is still at least a taka.
 */
export const MIN_PAYMENT_TOLERANCE_MINOR = 100;

/** The ± band around `expectedMinor` that still counts as the same payment. */
export function paymentToleranceMinor(expectedMinor: number): number {
	if (!Number.isFinite(expectedMinor) || expectedMinor <= 0) return 0;

	const twoPercent = Math.floor((expectedMinor * CASH_OUT_PER_THOUSAND_MAX) / 1000);
	return Math.max(MIN_PAYMENT_TOLERANCE_MINOR, twoPercent);
}

/** Whether a received amount is close enough to be the payment for this bill. */
export function isWithinPaymentTolerance(
	receivedMinor: number,
	expectedMinor: number,
): boolean {
	if (!Number.isFinite(receivedMinor) || receivedMinor <= 0) return false;
	return Math.abs(receivedMinor - expectedMinor) <= paymentToleranceMinor(expectedMinor);
}

/**
 * What to do with a sale when a mobile-money message backs it.
 *
 * - `merge`: the message is the whole payment (exact, or inside the cash-out
 *   band, where the customer added or the shop absorbed the charge).
 * - `split`: the message covers part of the bill and the customer handed over
 *   the rest in cash. The caller books a second cash row.
 * - `separate`: the message is too far from the bill to belong to it; the sale
 *   is recorded as its own row and the message stays untouched.
 * - `invalid`: the client sent a cash balance that does not add up. Rejecting
 *   is safer than guessing and writing a wrong ledger.
 */
export type SalePaymentResolution =
	| { mode: "merge" }
	| { mode: "split"; cashMinor: number }
	| { mode: "separate" }
	| { mode: "invalid"; message: string };

export function resolveSalePayment(input: {
	receivedMinor: number;
	totalMinor: number;
	/** Cash the customer also handed over, when the client says it did. */
	cashMinor?: number;
}): SalePaymentResolution {
	const { receivedMinor, totalMinor } = input;
	const cashMinor = input.cashMinor ?? 0;

	if (!Number.isFinite(receivedMinor) || receivedMinor <= 0) {
		return { mode: "separate" };
	}
	if (!Number.isFinite(totalMinor) || totalMinor <= 0) {
		return { mode: "invalid", message: "The sale total must be greater than zero" };
	}

	if (cashMinor > 0) {
		if (receivedMinor >= totalMinor) {
			return {
				mode: "invalid",
				message: "The payment message already covers the receipt",
			};
		}
		const balanceMinor = totalMinor - receivedMinor;
		if (cashMinor !== balanceMinor) {
			return {
				mode: "invalid",
				message: `The cash balance must be exactly ${balanceMinor} minor units`,
			};
		}
		return { mode: "split", cashMinor };
	}

	if (isWithinPaymentTolerance(receivedMinor, totalMinor)) return { mode: "merge" };
	return { mode: "separate" };
}
