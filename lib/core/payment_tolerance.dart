/// How far a mobile-money payment may sit from the sale total and still be the
/// same payment.
///
/// Cash-out charges on bKash/Nagad/Rocket/UPI run about **10-20 taka per
/// thousand** (1-2%). A customer paying by mobile money usually adds that charge
/// to what they send, and sometimes the shop absorbs it instead, so the
/// confirmation SMS is a few taka away from the bill either way.
///
/// Anything inside this band is treated as the payment for the sale, so the
/// ledger links the SMS row instead of booking a second inflow.
library;

import 'money.dart';

/// The low end of the cash-out charge: 10 taka per thousand.
const int kCashOutPerThousandMin = 10;

/// The high end of the cash-out charge: 20 taka per thousand.
const int kCashOutPerThousandMax = 20;

/// Floor for very small bills: below ~50 taka, 2% rounds to nothing, yet the
/// charge is still at least a taka.
const int kMinPaymentToleranceMinor = 100;

/// The ± band around [expectedMinor] that still counts as the same payment.
///
/// Uses the top of the cash-out range (2%) so a customer who adds the charge is
/// never rejected, and a floor so tiny bills behave sensibly. Integer maths only:
/// money never touches a double.
int paymentToleranceMinor(int expectedMinor) {
  if (expectedMinor <= 0) return 0;

  final int twoPercent = (expectedMinor * kCashOutPerThousandMax) ~/ 1000;
  return twoPercent < kMinPaymentToleranceMinor
      ? kMinPaymentToleranceMinor
      : twoPercent;
}

/// How a received amount relates to the bill.
enum PaymentAmountFit {
  /// Exactly the sale total.
  exact,

  /// Inside the cash-out band — still the payment for this sale.
  cashOut,

  /// Too far apart to be the same payment.
  outside,
}

/// A received payment amount compared against the sale total.
class PaymentAmountMatch {
  const PaymentAmountMatch({
    required this.receivedMinor,
    required this.expectedMinor,
    this.currency = 'BDT',
  });

  /// What the SMS says the customer sent.
  final int receivedMinor;

  /// The sale total.
  final int expectedMinor;

  final String currency;

  /// Signed: positive when the customer added the cash-out charge, negative when
  /// the shop absorbed it.
  int get differenceMinor => receivedMinor - expectedMinor;

  int get toleranceMinor => paymentToleranceMinor(expectedMinor);

  PaymentAmountFit get fit {
    if (receivedMinor <= 0) return PaymentAmountFit.outside;
    if (differenceMinor == 0) return PaymentAmountFit.exact;
    if (differenceMinor.abs() <= toleranceMinor) {
      return PaymentAmountFit.cashOut;
    }
    return PaymentAmountFit.outside;
  }

  bool get isExact => fit == PaymentAmountFit.exact;

  /// True for an exact match and for one inside the cash-out band: either way
  /// this message is the payment for the sale.
  bool get isAttachable => fit != PaymentAmountFit.outside;

  /// "+৳ 2" for a charge the customer added, "-৳ 2" for one the shop absorbed.
  /// Empty for an exact match.
  String get differenceLabel {
    if (differenceMinor == 0) return '';
    final String sign = differenceMinor > 0 ? '+' : '-';
    return '$sign${formatMinorCompact(differenceMinor.abs(), currency: currency)}';
  }

  /// Human sentence for the payment sheet: "৳ 2 cash-out charge".
  String get cashOutLabel {
    if (differenceMinor == 0) return 'Matches total';
    return '$differenceLabel cash-out charge';
  }
}
