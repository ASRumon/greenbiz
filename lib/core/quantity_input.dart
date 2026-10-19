/// Parsing and input filtering for the two numbers a shopkeeper types on the
/// sell screen: a **quantity** ("2.5 kg") and a **money amount** ("৳20").
///
/// Both accept Bengali or Devanagari digits and a comma as the decimal
/// separator, because a Bengali keyboard does not always produce the ASCII
/// forms. Nothing here ever turns a partially typed value into an exception:
/// invalid input is reported inline by the dialog that owns the field.
library;

import 'package:flutter/services.dart';

import '../models/product.dart';
import 'money.dart';

/// Size of the smallest fraction the app accepts. Stock is a REAL column, and
/// a kilo can be split into grams, so three decimals is enough for every unit
/// the catalogue uses.
const int kQuantityDecimals = 3;

/// Turns Bengali (০-৯) and Devanagari (०-९) digits into ASCII digits.
String normalizeNumericDigits(String input) {
  final StringBuffer buffer = StringBuffer();
  for (final int codePoint in input.runes) {
    if (codePoint >= 0x09e6 && codePoint <= 0x09ef) {
      buffer.write(codePoint - 0x09e6);
    } else if (codePoint >= 0x0966 && codePoint <= 0x096f) {
      buffer.write(codePoint - 0x0966);
    } else {
      buffer.writeCharCode(codePoint);
    }
  }
  return buffer.toString();
}

/// Parses "2", "2.5", "২.৫", "2,5" or ".5" into a quantity.
///
/// Returns null for anything that is not a clean number, so the caller can show
/// "Enter a quantity" instead of silently doing nothing.
double? parseQuantityText(String input) {
  final String text = normalizeNumericDigits(input).replaceAll(',', '.').trim();
  if (text.isEmpty) return null;

  final RegExpMatch? match = RegExp(r'^(\d*)(?:\.(\d{0,3}))?$')
      .firstMatch(text);
  if (match == null) return null;

  final String wholeText = match.group(1) ?? '';
  final String fractionText = match.group(2) ?? '';
  if (wholeText.isEmpty && fractionText.isEmpty) return null;

  final int whole = wholeText.isEmpty ? 0 : int.parse(wholeText);
  final int fraction = fractionText.isEmpty
      ? 0
      : int.parse(fractionText.padRight(kQuantityDecimals, '0'));

  return whole + fraction / 1000;
}

/// Parses "20", "20.50", "২০", "20,5" into minor units.
///
/// The comma is treated as a decimal separator, not a thousands separator: the
/// input filters on the sell screen allow exactly one separator and at most two
/// fraction digits, so "1,500" cannot reach this function.
int? parseMoneyText(String input) {
  var text = normalizeNumericDigits(input).replaceAll(',', '.').trim();
  if (text.isEmpty) return null;
  // "20." is a natural half-typed value; treat it as 20.
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return parseMajorToMinor(text);
}

/// Quantity bought for [amountMinor] at [unitPriceMinor].
///
/// Rounded to six decimals before it goes back into a text field, which is
/// enough for the line total to round back to exactly the amount the customer
/// asked for.
double? quantityForAmount({
  required int amountMinor,
  required int unitPriceMinor,
}) {
  if (amountMinor <= 0 || unitPriceMinor <= 0) return null;
  final double raw = amountMinor / unitPriceMinor;
  if (!raw.isFinite) return null;
  return double.parse(raw.toStringAsFixed(6));
}

/// The money a line costs, rounded exactly the way the server rounds it.
int lineTotalFor({required int unitPriceMinor, required double quantity}) =>
    (unitPriceMinor * quantity).round();

/// Units that are sold as whole items, where a fractional quantity makes no
/// sense ("0.09 of a calculator").
///
/// Only units that are genuinely divisible are fractional. Everything else —
/// piece, box, packet, or a custom unit the shop typed in — is treated as a
/// whole item, so the app never invents a fraction of something it does not
/// understand.
bool isDiscreteUnit(String unit) {
  final normalized = unit.toLowerCase().trim();
  if (normalized.isEmpty) return true;

  const Set<String> fractional = <String>{
    'kg',
    'g',
    'gram',
    'grams',
    'kilogram',
    'kilograms',
    'ton',
    'tons',
    'quintal',
    'litre',
    'liter',
    'litres',
    'liters',
    'ml',
    'millilitre',
    'milliliter',
    'metre',
    'meter',
    'metres',
    'meters',
    'yard',
    'yards',
    'sqft',
    'sft',
    'sqm',
    'dozen',
  };
  return !fractional.contains(normalized);
}

/// Turns a money budget into a quantity, keeping discrete units whole.
///
/// A ৳70 budget for a ৳800 calculator cannot buy a fraction of one, so the
/// quantity falls back to [fallbackQuantity] and [warning] carries the
/// per-item price. A ৳70 budget for ৳20 packets buys 3 packets and warns about
/// the ৳10 left over.
({double quantity, String? warning}) resolveAmountQuantity({
  required Product product,
  required int amountMinor,
  required double fallbackQuantity,
}) {
  final double? fromAmount = quantityForAmount(
    amountMinor: amountMinor,
    unitPriceMinor: product.unitPriceMinor,
  );
  if (fromAmount == null) {
    return (quantity: fallbackQuantity, warning: 'set a selling price first');
  }

  if (!isDiscreteUnit(product.unit)) {
    return (quantity: fromAmount, warning: null);
  }

  final int whole = fromAmount.floor();
  if (whole >= 1) {
    if ((fromAmount - whole).abs() <= 0.001) {
      return (quantity: whole.toDouble(), warning: null);
    }

    final int spentMinor = product.unitPriceMinor * whole;
    final int remainderMinor = amountMinor - spentMinor;
    return (
      quantity: whole.toDouble(),
      warning:
          'sold per ${product.unit}; $whole ${product.unit} = '
          '${formatMinor(spentMinor)}'
          '${remainderMinor > 0 ? ', ${formatMinor(remainderMinor)} left over' : ''}',
    );
  }

  return (
    quantity: fallbackQuantity,
    warning:
        'sold per ${product.unit}; 1 ${product.unit} is '
        '${formatMinor(product.unitPriceMinor)}',
  );
}

/// Round-down suggestions for a bill: nearest ৳5, nearest ৳10, and whole taka
/// when the bill has paisa.
///
/// Mirrors the way a shopkeeper rounds ("৳257, give me ৳250"). Only amounts
/// that actually reduce the bill are returned, largest first, so the chip
/// closest to the real bill is offered first. Anything bigger is a custom
/// amount, not a round-off.
List<int> roundDownOptions(int billMinor, {int limit = 3}) {
  if (billMinor <= 0) return const <int>[];

  final Set<int> options = <int>{};
  // Steps are in minor units: 500 = ৳5, 1000 = ৳10.
  for (final int step in <int>[500, 1000]) {
    final int down = (billMinor ~/ step) * step;
    if (down > 0 && down < billMinor) options.add(down);
  }
  final int wholeTaka = (billMinor ~/ 100) * 100;
  if (wholeTaka > 0 && wholeTaka < billMinor) options.add(wholeTaka);

  final List<int> sorted = options.toList()
    ..sort((int a, int b) => b.compareTo(a));
  return sorted.take(limit).toList(growable: false);
}

/// A text formatter for decimal fields.
///
/// It keeps at most one decimal separator and [decimalDigits] fraction digits.
/// Anything beyond that is simply not inserted, which is friendlier than letting
/// the value through and rejecting it later with a red error.
class DecimalInputFormatter extends TextInputFormatter {
  DecimalInputFormatter({this.decimalDigits = 3});

  final int decimalDigits;

  static final RegExp _allowed = RegExp(r'^[0-9০-৯]+[.,]?[0-9০-৯]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    if (text.isEmpty) return newValue;
    if (!_allowed.hasMatch(text)) return oldValue;

    final int separator = text.indexOf(RegExp(r'[.,]'));
    if (separator != -1 && text.length - separator - 1 > decimalDigits) {
      return oldValue;
    }
    return newValue;
  }
}
