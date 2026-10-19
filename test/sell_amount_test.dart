import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/quantity_input.dart';
import 'package:greenbiz/models/product.dart';

/// The two amounts a sale can start from:
///   * "give me ৳20 of onion" -> quantity, and
///   * "the bill is ৳257, give me ৳250" -> collected amount and discount.
void main() {
  group('parseQuantityText', () {
    test('accepts whole, fractional and local digits', () {
      expect(parseQuantityText('2'), 2);
      expect(parseQuantityText('2.5'), 2.5);
      expect(parseQuantityText('২.৫'), 2.5);
      expect(parseQuantityText('2,5'), 2.5);
      expect(parseQuantityText('.5'), 0.5);
      expect(parseQuantityText('0.333'), 0.333);
    });

    test('rejects malformed input instead of guessing', () {
      expect(parseQuantityText(''), isNull);
      expect(parseQuantityText('.'), isNull);
      expect(parseQuantityText('1.2.3'), isNull);
      expect(parseQuantityText('1.2345'), isNull);
      expect(parseQuantityText('abc'), isNull);
    });
  });

  group('sell by amount', () {
    test('turns ৳20 at ৳60/kg into 0.333 kg and back to ৳20', () {
      final double quantity = quantityForAmount(
        amountMinor: 2000,
        unitPriceMinor: 6000,
      )!;

      expect(quantity, closeTo(0.333333, 1e-9));
      expect(lineTotalFor(unitPriceMinor: 6000, quantity: quantity), 2000);
    });

    test('a third of a unit still rounds back to the amount asked for', () {
      final double quantity = quantityForAmount(
        amountMinor: 1000,
        unitPriceMinor: 3000,
      )!;

      expect(lineTotalFor(unitPriceMinor: 3000, quantity: quantity), 1000);
    });

    test('refuses a zero price or amount', () {
      expect(quantityForAmount(amountMinor: 0, unitPriceMinor: 100), isNull);
      expect(quantityForAmount(amountMinor: 100, unitPriceMinor: 0), isNull);
    });
  });

  group('parseMoneyText', () {
    test('accepts ASCII, local digits and a comma separator', () {
      expect(parseMoneyText('20'), 2000);
      expect(parseMoneyText('২০'), 2000);
      expect(parseMoneyText('20.50'), 2050);
      expect(parseMoneyText('20,5'), 2050);
      expect(parseMoneyText('20.'), 2000);
    });

    test('rejects nonsense', () {
      expect(parseMoneyText(''), isNull);
      expect(parseMoneyText('abc'), isNull);
      expect(parseMoneyText('1.005'), isNull);
    });
  });

  group('roundDownOptions', () {
    test('offers the amounts a shopkeeper would say for ৳257', () {
      expect(roundDownOptions(25700), <int>[25500, 25000]);
    });

    test('rounds a bill with paisa to whole taka first', () {
      expect(roundDownOptions(25750), <int>[25700, 25500, 25000]);
    });

    test('offers nothing when the bill is already round', () {
      expect(roundDownOptions(4000), isEmpty);
      expect(roundDownOptions(0), isEmpty);
    });
  });

  group('whole-piece units', () {
    Product product(String unit, int priceMinor) => Product(
      id: 'p-1',
      shopId: 'shop-1',
      productName: 'Item',
      unit: unit,
      unitPriceMinor: priceMinor,
      stockQuantity: 10,
    );

    test('only divisible units allow fractions', () {
      expect(isDiscreteUnit('piece'), isTrue);
      expect(isDiscreteUnit('box'), isTrue);
      expect(isDiscreteUnit('packet'), isTrue);
      // A custom unit is treated as a whole item.
      expect(isDiscreteUnit('calculator'), isTrue);
      expect(isDiscreteUnit('kg'), isFalse);
      expect(isDiscreteUnit('litre'), isFalse);
      expect(isDiscreteUnit('dozen'), isFalse);
    });

    test('a small budget for a calculator keeps one whole piece', () {
      final result = resolveAmountQuantity(
        product: product('piece', 80000),
        amountMinor: 7000,
        fallbackQuantity: 1,
      );

      expect(result.quantity, 1);
      expect(result.warning, contains('sold per piece'));
    });

    test('a budget that buys whole pieces uses the whole count', () {
      final result = resolveAmountQuantity(
        product: product('piece', 80000),
        amountMinor: 160000,
        fallbackQuantity: 1,
      );

      expect(result.quantity, 2);
      expect(result.warning, isNull);
    });

    test('a packet budget buys whole packets and reports the change', () {
      final result = resolveAmountQuantity(
        product: product('packet', 2000),
        amountMinor: 7000,
        fallbackQuantity: 1,
      );

      expect(result.quantity, 3);
      expect(result.warning, contains('left over'));
    });

    test('weight stays fractional', () {
      final result = resolveAmountQuantity(
        product: product('kg', 6000),
        amountMinor: 7000,
        fallbackQuantity: 1,
      );

      expect(result.quantity, closeTo(70 / 60, 1e-6));
      expect(result.warning, isNull);
    });
  });
}
