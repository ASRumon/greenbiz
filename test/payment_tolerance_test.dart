import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/payment_tolerance.dart';

/// Cash-out charges run about 10-20 taka per thousand, so a mobile-money
/// confirmation rarely lands on the exact sale total. These tests pin the band
/// the app treats as "the same payment".
PaymentAmountMatch _match(int receivedMinor, int expectedMinor) =>
    PaymentAmountMatch(
      receivedMinor: receivedMinor,
      expectedMinor: expectedMinor,
    );

void main() {
  group('paymentToleranceMinor', () {
    test('uses the top of the cash-out range: 20 taka per thousand', () {
      // 1,000.00 taka -> 20.00 taka of slack.
      expect(paymentToleranceMinor(100000), 2000);
      // 500.00 taka -> 10.00 taka of slack.
      expect(paymentToleranceMinor(50000), 1000);
    });

    test('keeps a one-taka floor for very small bills', () {
      expect(paymentToleranceMinor(1000), kMinPaymentToleranceMinor);
      expect(paymentToleranceMinor(100), kMinPaymentToleranceMinor);
    });

    test('has no band for a zero or negative bill', () {
      expect(paymentToleranceMinor(0), 0);
      expect(paymentToleranceMinor(-500), 0);
    });

    test('the band stays inside the real cash-out range', () {
      // 10 taka per thousand is the low end of the charge, and it must sit
      // inside the accepted band.
      const int bill = 100000;
      final int lowEnd = (bill * kCashOutPerThousandMin) ~/ 1000;
      final int highEnd = (bill * kCashOutPerThousandMax) ~/ 1000;

      expect(paymentToleranceMinor(bill), greaterThanOrEqualTo(highEnd));
      expect(lowEnd, lessThan(paymentToleranceMinor(bill) + 1));
    });
  });

  group('PaymentAmountMatch', () {
    const int bill = 100000; // ৳1,000.00

    test('an exact amount is the sale itself', () {
      final PaymentAmountMatch match = _match(bill, bill);

      expect(match.fit, PaymentAmountFit.exact);
      expect(match.isExact, isTrue);
      expect(match.isAttachable, isTrue);
      expect(match.differenceMinor, 0);
      expect(match.differenceLabel, isEmpty);
      expect(match.cashOutLabel, 'Matches total');
    });

    test('a customer who adds the cash-out charge still matches', () {
      final PaymentAmountMatch match = _match(bill + 1500, bill);

      expect(match.fit, PaymentAmountFit.cashOut);
      expect(match.isAttachable, isTrue);
      expect(match.differenceMinor, 1500);
      expect(match.differenceLabel, '+৳ 15');
      expect(match.cashOutLabel, '+৳ 15 cash-out charge');
    });

    test('a shop that absorbs the charge still matches', () {
      final PaymentAmountMatch match = _match(bill - 2000, bill);

      expect(match.fit, PaymentAmountFit.cashOut);
      expect(match.differenceMinor, -2000);
      expect(match.differenceLabel, '-৳ 20');
    });

    test('a payment from another sale is outside the band', () {
      final PaymentAmountMatch match = _match(bill - 5000, bill);

      expect(match.fit, PaymentAmountFit.outside);
      expect(match.isAttachable, isFalse);
    });

    test('an empty or negative amount never matches', () {
      expect(_match(0, bill).fit, PaymentAmountFit.outside);
      expect(_match(-1000, bill).fit, PaymentAmountFit.outside);
    });

    test('the band grows with the bill', () {
      // ৳50 of slack on a ৳1,000 bill would be a lot; the same ৳50 on ৳10,000
      // is well inside the charge band.
      expect(_match(100000 + 5000, 100000).fit, PaymentAmountFit.outside);
      expect(_match(1000000 + 5000, 1000000).fit, PaymentAmountFit.cashOut);
    });

    test('a different currency keeps its own symbol', () {
      final PaymentAmountMatch match = PaymentAmountMatch(
        receivedMinor: 100500,
        expectedMinor: 100000,
        currency: 'INR',
      );

      expect(match.differenceLabel, '+\u20B9 5');
    });
  });
}
