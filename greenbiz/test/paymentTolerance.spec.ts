import { describe, expect, it } from "vitest";
import {
	CASH_OUT_PER_THOUSAND_MAX,
	CASH_OUT_PER_THOUSAND_MIN,
	isWithinPaymentTolerance,
	MIN_PAYMENT_TOLERANCE_MINOR,
	paymentToleranceMinor,
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
