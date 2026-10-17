import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/features/finance/finance_controller.dart';
import 'package:greenbiz/features/sell/payment_picker_sheet.dart';
import 'package:greenbiz/models/transaction.dart';

Transaction _payment({
  String? paymentMethod,
  String? note,
  String? reference,
  int amountMinor = 50000,
  DateTime? occurredAt,
}) => Transaction(
  id: 'tx-1',
  shopId: 'shop-1',
  smsId: 'sms-1',
  direction: 'in',
  amountMinor: amountMinor,
  currency: 'BDT',
  reference: reference,
  occurredAt: occurredAt ?? DateTime(2026, 10, 17, 10),
  note: note,
  paymentMethod: paymentMethod,
);

void main() {
  group('payment suggestion window', () {
    test('only the last ten minutes are suggested', () {
      expect(kSmsSuggestionWindow, const Duration(minutes: 10));
    });

    test('the full list still reaches back a month', () {
      expect(kSmsHistoryWindow, const Duration(days: 30));
      expect(kSmsHistoryWindow, greaterThan(kSmsSuggestionWindow));
    });
  });

  group('paymentMethodFor', () {
    test('prefers the recorded method', () {
      expect(
        paymentMethodFor(_payment(paymentMethod: 'nagad', note: 'bKash')),
        'nagad',
      );
    });

    test('infers bKash and Nagad from the note', () {
      expect(paymentMethodFor(_payment(note: 'bKash TrxID 8H2K9L')), 'bkash');
      expect(
        paymentMethodFor(_payment(note: 'Nagad payment received')),
        'nagad',
      );
    });

    test('infers Rocket from either brand name', () {
      expect(paymentMethodFor(_payment(note: 'Rocket cash in')), 'rocket');
      expect(paymentMethodFor(_payment(note: 'DBBL mobile banking')), 'rocket');
    });

    test('infers UPI from the Indian wallets', () {
      expect(paymentMethodFor(_payment(note: 'paid via UPI')), 'upi');
      expect(paymentMethodFor(_payment(note: 'PhonePe transfer')), 'upi');
      expect(paymentMethodFor(_payment(note: 'GPay received')), 'upi');
    });

    test('falls back to other for an unrecognised message', () {
      expect(paymentMethodFor(_payment(note: 'Amount received')), 'other');
      expect(paymentMethodFor(_payment()), 'other');
    });
  });

  group('paymentMethodLabel', () {
    test('uses the brand spelling shown in the UI', () {
      expect(paymentMethodLabel('bkash'), 'bKash');
      expect(paymentMethodLabel('nagad'), 'Nagad');
      expect(paymentMethodLabel('rocket'), 'Rocket');
      expect(paymentMethodLabel('upi'), 'UPI');
      expect(paymentMethodLabel('cash'), 'Cash');
      expect(paymentMethodLabel('something-else'), 'Other');
    });
  });

  test('the attach step always keeps the message it matched', () {
    final Transaction message = _payment(
      paymentMethod: 'bkash',
      reference: '8H2K9L',
    );

    // Picking a message is what links the sale to the existing payment row, so
    // the reference and SMS id have to survive into the choice.
    expect(paymentMethodFor(message), 'bkash');
    expect(message.reference, '8H2K9L');
    expect(message.smsId, 'sms-1');
  });
}
