import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/ids.dart';
import 'package:greenbiz/models/sale.dart';
import 'package:greenbiz/models/transaction.dart';

Transaction _transactionJson(Map<String, dynamic> overrides) =>
    Transaction.fromJson(<String, dynamic>{
      'id': 'tx-1',
      'shopId': 'shop-1',
      'direction': 'in',
      'amountMinor': 150000,
      'currency': 'BDT',
      'occurredAt': 1700000000000,
      ...overrides,
    });

void main() {
  group('transaction business flag', () {
    test('defaults to business when the field is absent', () {
      expect(_transactionJson(<String, dynamic>{}).isBusiness, isTrue);
    });

    test('accepts a JSON bool', () {
      expect(
        _transactionJson(<String, dynamic>{'isBusiness': false}).isBusiness,
        isFalse,
      );
      expect(
        _transactionJson(<String, dynamic>{'isBusiness': true}).isBusiness,
        isTrue,
      );
    });

    test('accepts SQLite 0/1', () {
      expect(
        _transactionJson(<String, dynamic>{'isBusiness': 0}).isBusiness,
        isFalse,
      );
      expect(
        _transactionJson(<String, dynamic>{'isBusiness': 1}).isBusiness,
        isTrue,
      );
    });

    test('copyWith flips business without losing the rest of the row', () {
      final Transaction original = _transactionJson(<String, dynamic>{});
      final Transaction personal = original.copyWith(
        isBusiness: false,
        syncState: 1,
      );

      expect(personal.isBusiness, isFalse);
      expect(personal.isPending, isTrue);
      expect(personal.amountMinor, original.amountMinor);
      expect(personal.direction, original.direction);
    });

    test('SMS rows remain identifiable after a business toggle', () {
      final Transaction sms = _transactionJson(<String, dynamic>{
        'smsId': 'sms-9',
      });
      expect(sms.isFromSms, isTrue);
      expect(sms.copyWith(isBusiness: false).isFromSms, isTrue);
    });

    test('parses the payment method and mobile-money reference', () {
      final Transaction transaction = _transactionJson(<String, dynamic>{
        'paymentMethod': 'bkash',
        'reference': 'TRX123456',
      });

      expect(transaction.paymentMethod, 'bkash');
      expect(transaction.paymentMethodLabel, 'bKash');
      expect(transaction.reference, 'TRX123456');
    });

    test('labels every supported payment method', () {
      expect(
        _transactionJson(<String, dynamic>{'paymentMethod': 'cash'})
            .paymentMethodLabel,
        'Cash',
      );
      expect(
        _transactionJson(<String, dynamic>{'paymentMethod': 'nagad'})
            .paymentMethodLabel,
        'Nagad',
      );
      expect(
        _transactionJson(<String, dynamic>{'paymentMethod': 'rocket'})
            .paymentMethodLabel,
        'Rocket',
      );
      expect(
        _transactionJson(<String, dynamic>{'paymentMethod': 'upi'})
            .paymentMethodLabel,
        'UPI',
      );
    });
  });

  group('offline ids', () {
    test('generates RFC 4122 v4 UUIDs', () {
      final RegExp v4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );

      for (var i = 0; i < 50; i++) {
        expect(v4.hasMatch(newUuid()), isTrue, reason: newUuid());
      }
    });

    test('does not repeat', () {
      final Set<String> ids = <String>{for (var i = 0; i < 200; i++) newUuid()};
      expect(ids.length, 200);
    });
  });

  group('sale receipt cache fields', () {
    test('parses the server remaining stock when present', () {
      final SaleReceipt receipt = SaleReceipt.fromJson(<String, dynamic>{
        'transaction': <String, dynamic>{'id': 'tx-1'},
        'totalMinor': 4998,
        'currency': 'BDT',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'productId': 'p-1',
            'productName': 'Rice',
            'unit': 'kg',
            'quantity': 2.5,
            'unitPriceMinor': 1999,
            'lineTotalMinor': 4998,
            'remainingStock': 7.5,
          },
        ],
      });

      expect(receipt.items.single.remainingStock, 7.5);
    });

    test('leaves remaining stock null when the server omits it', () {
      final SaleReceipt receipt = SaleReceipt.fromJson(<String, dynamic>{
        'transaction': <String, dynamic>{'id': 'tx-1'},
        'totalMinor': 100,
        'currency': 'BDT',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'productId': 'p-1',
            'productName': 'Tea',
            'unit': 'piece',
            'quantity': 1,
            'unitPriceMinor': 100,
            'lineTotalMinor': 100,
          },
        ],
      });

      expect(receipt.items.single.remainingStock, isNull);
    });

    test('reads the payment method and reference from the transaction', () {
      final SaleReceipt receipt = SaleReceipt.fromJson(<String, dynamic>{
        'transaction': <String, dynamic>{
          'id': 'tx-1',
          'paymentMethod': 'nagad',
          'reference': 'NGD9988',
        },
        'totalMinor': 5000,
        'currency': 'BDT',
        'items': <Map<String, dynamic>>[],
      });

      expect(receipt.paymentMethod, 'nagad');
      expect(receipt.paymentMethodLabel, 'Nagad');
      expect(receipt.reference, 'NGD9988');
    });
  });
}
