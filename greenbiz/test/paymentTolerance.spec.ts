import { describe, expect, it } from "vitest";
import {
	CASH_OUT_PER_THOUSAND_MAX,
	CASH_OUT_PER_THOUSAND_MIN,
	isWithinPaymentTolerance,
	MIN_PAYMENT_TOLERANCE_MINOR,
	paymentToleranceMinor,
	resolveSalePayment,
} from "../src/lib/paymentTolerance";

/**
 * The sale merge depends on this band: a confirmation message inside it is the
 * payment for the sale, so the server links the row instead of booking a second
 * inflow. Same rule as `lib/core/payment_tolerance.dart` in the app.
 */

describe("paymentToleranceMinor", () => {
	it("allows 20 taka per thousand, the top of the cash-out range", () => {
		expect(paymentToleranceMinor(100000)).toBe(2000);
		expect(paymentToleranceMinor(50000)).toBe(1000);
	});

	it("keeps a one-taka floor for tiny bills", () => {
		expect(paymentToleranceMinor(1000)).toBe(MIN_PAYMENT_TOLERANCE_MINOR);
	});

	it("covers the whole 10-20 taka per thousand charge range", () => {
		const bill = 100000;
		const lowEnd = Math.floor((bill * CASH_OUT_PER_THOUSAND_MIN) / 1000);
		const highEnd = Math.floor((bill * CASH_OUT_PER_THOUSAND_MAX) / 1000);

		expect(paymentToleranceMinor(bill)).toBeGreaterThanOrEqual(highEnd);
		expect(paymentToleranceMinor(bill)).toBeGreaterThanOrEqual(lowEnd);
	});

	it("has no band for a zero, negative, or non-finite bill", () => {
		expect(paymentToleranceMinor(0)).toBe(0);
		expect(paymentToleranceMinor(-500)).toBe(0);
		expect(paymentToleranceMinor(Number.NaN)).toBe(0);
	});
});

describe("isWithinPaymentTolerance", () => {
	it("accepts the exact total", () => {
		expect(isWithinPaymentTolerance(100000, 100000)).toBe(true);
	});

	it("accepts the customer adding the cash-out charge", () => {
		expect(isWithinPaymentTolerance(101500, 100000)).toBe(true);
	});

	it("accepts the shop absorbing the cash-out charge", () => {
		expect(isWithinPaymentTolerance(98000, 100000)).toBe(true);
	});

	it("rejects a payment from a different sale", () => {
		expect(isWithinPaymentTolerance(95000, 100000)).toBe(false);
		expect(isWithinPaymentTolerance(120000, 100000)).toBe(false);
	});

	it("rejects a zero or negative amount", () => {
		expect(isWithinPaymentTolerance(0, 100000)).toBe(false);
		expect(isWithinPaymentTolerance(-1000, 100000)).toBe(false);
	});
});

describe("resolveSalePayment", () => {
	it("merges an exact message", () => {
		expect(resolveSalePayment({ receivedMinor: 40000, totalMinor: 40000 })).toEqual({
			mode: "merge",
		});
	});

	it("merges a message inside the cash-out band", () => {
		expect(resolveSalePayment({ receivedMinor: 40160, totalMinor: 40000 })).toEqual({
			mode: "merge",
		});
	});

	it("splits a short message when the cash adds up", () => {
		// ৳30 by bKash + ৳10 cash for a ৳40 sale.
		expect(
			resolveSalePayment({ receivedMinor: 3000, totalMinor: 4000, cashMinor: 1000 }),
		).toEqual({ mode: "split", cashMinor: 1000 });
	});

	it("splits a rounded-down bill", () => {
		// Bill ৳257, owner collected ৳250, customer sent ৳200 by bKash and ৳50 cash.
		expect(
			resolveSalePayment({ receivedMinor: 20000, totalMinor: 25000, cashMinor: 5000 }),
		).toEqual({ mode: "split", cashMinor: 5000 });
	});

	it("rejects a cash balance that does not add up", () => {
		const result = resolveSalePayment({
			receivedMinor: 3000,
			totalMinor: 4000,
			cashMinor: 500,
		});
		expect(result.mode).toBe("invalid");
	});

	it("rejects cash when the message already covers the bill", () => {
		const result = resolveSalePayment({
			receivedMinor: 4000,
			totalMinor: 4000,
			cashMinor: 1000,
		});
		expect(result.mode).toBe("invalid");
	});

	it("keeps a message from another sale separate", () => {
		expect(resolveSalePayment({ receivedMinor: 50000, totalMinor: 40000 })).toEqual({
			mode: "separate",
		});
	});

	it("ignores an empty message", () => {
		expect(resolveSalePayment({ receivedMinor: 0, totalMinor: 40000 })).toEqual({
			mode: "separate",
		});
	});
});
