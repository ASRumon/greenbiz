import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/models/transaction.dart';

Transaction _sale({
  required int amountMinor,
  required int subtotalMinor,
  required int discountMinor,
}) => Transaction(
  id: 'tx-1',
  shopId: 'shop-1',
  direction: 'in',
  amountMinor: amountMinor,
  currency: 'BDT',
  occurredAt: DateTime(2026, 10, 19),
  paymentMethod: 'cash',
  subtotalMinor: subtotalMinor,
  discountMinor: discountMinor,
);

/// The payment screen must lead with the discounted amount, in Taka.
void main() {
  test('a rounded bill shows the collected amount and the discount', () {
    final Transaction transaction = _sale(
      amountMinor: 25000,
      subtotalMinor: 25700,
      discountMinor: 700,
    );

    expect(transaction.saleTotalMinor, 25000);
    expect(transaction.hasSaleBreakdown, isTrue);
    expect(transaction.amountDiffersFromSale, isFalse);
    expect(
      transaction.saleBreakdownLabel,
      'Sale \u09F3 250.00 · Bill \u09F3 257.00 · \u09F3 7.00 discount',
    );
  });

  test('a merged message shows the received amount when it differs', () {
    // A ৳260 message for a ৳250 sale: the extra ৳10 is the cash-out charge.
    final Transaction transaction = _sale(
      amountMinor: 26000,
      subtotalMinor: 25700,
      discountMinor: 700,
    );

    expect(transaction.saleTotalMinor, 25000);
    expect(transaction.amountDiffersFromSale, isTrue);
    expect(
      transaction.saleBreakdownLabel,
      'Sale \u09F3 250.00 · Bill \u09F3 257.00 · \u09F3 7.00 discount'
      ' · Received \u09F3 260.00',
    );
  });

  test('the cash half of a split sale has no breakdown of its own', () {
    final Transaction cash = _sale(
      amountMinor: 1000,
      subtotalMinor: 0,
      discountMinor: 0,
    );

    expect(cash.hasSaleBreakdown, isFalse);
    expect(cash.saleTotalMinor, 1000);
  });

  test('a plain manual payment falls back to its amount', () {
    final Transaction manual = Transaction(
      id: 'tx-2',
      shopId: 'shop-1',
      direction: 'in',
      amountMinor: 50000,
      currency: 'BDT',
      occurredAt: DateTime(2026, 10, 19),
    );

    expect(manual.hasSaleBreakdown, isFalse);
    expect(manual.saleTotalMinor, 50000);
    expect(manual.amountDiffersFromSale, isFalse);
  });
}
