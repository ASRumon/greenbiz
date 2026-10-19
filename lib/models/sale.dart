import '../core/money.dart';
import 'product.dart';
import 'transaction.dart';

/// One "3 kg of rice" on a sale.
///
/// [quantity] is a double because stock is a REAL column — half a kilo is a
/// normal sale. Money stays an integer in minor units: [lineTotalMinor] rounds
/// once, at the line level, and the server rounds the same way.
class SaleLine {
  const SaleLine({required this.product, required this.quantity});

  final Product product;
  final double quantity;

  int get lineTotalMinor => (product.unitPriceMinor * quantity).round();

  String get quantityLabel => formatQuantity(quantity);

  SaleLine copyWith({double? quantity}) =>
      SaleLine(product: product, quantity: quantity ?? this.quantity);
}

/// "3" for 3.0, "2.5" for 2.50, "0.333" for a third of a kilo — how a
/// shopkeeper writes a quantity, without trailing zeros.
///
/// Up to three decimals are kept because the sell screen can turn a money
/// amount into a quantity (৳20 of onion at ৳60/kg is 0.333 kg).
String formatQuantity(double quantity) {
  if (!quantity.isFinite) return '0';
  if (quantity == quantity.roundToDouble()) return quantity.toInt().toString();
  return quantity
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// One line of the receipt returned by the server.
///
/// The server's numbers are authoritative: the client displays exactly what was
/// recorded, not what it hoped would be recorded.
class SaleReceiptItem {
  const SaleReceiptItem({
    required this.productId,
    required this.productName,
    required this.unit,
    required this.quantity,
    required this.unitPriceMinor,
    required this.lineTotalMinor,
    this.remainingStock,
  });

  factory SaleReceiptItem.fromJson(Map<String, dynamic> json) =>
      SaleReceiptItem(
        productId: json['productId']?.toString() ?? '',
        productName: json['productName']?.toString() ?? '',
        unit: json['unit']?.toString() ?? 'unit',
        quantity: _asDouble(json['quantity']),
        unitPriceMinor: _asInt(json['unitPriceMinor']),
        lineTotalMinor: _asInt(json['lineTotalMinor']),
        remainingStock: json['remainingStock'] == null
            ? null
            : _asDouble(json['remainingStock']),
      );

  final String productId;
  final String productName;
  final String unit;
  final double quantity;
  final int unitPriceMinor;
  final int lineTotalMinor;

  /// Stock left after the server applied the sale, when it returned one.
  final double? remainingStock;

  String get quantityLabel => formatQuantity(quantity);
}

/// A completed sale.
class SaleReceipt {
  const SaleReceipt({
    required this.transactionId,
    required this.totalMinor,
    required this.currency,
    required this.items,
    this.subtotalMinor,
    this.discountMinor = 0,
    this.score,
    this.paymentMethod,
    this.reference,
    this.smsId,
    this.cashMinor = 0,
    this.cashTransaction,
  });

  factory SaleReceipt.fromJson(Map<String, dynamic> json) {
    final transaction = json['transaction'];
    final transactionMap = transaction is Map
        ? Map<String, dynamic>.from(transaction)
        : const <String, dynamic>{};

    final cashRaw = json['cashTransaction'];
    final cashTransaction = cashRaw is Map
        ? Transaction.fromJson(Map<String, dynamic>.from(cashRaw))
        : null;

    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (entry) =>
                    SaleReceiptItem.fromJson(Map<String, dynamic>.from(entry)),
              )
              .toList(growable: false)
        : const <SaleReceiptItem>[];

    return SaleReceipt(
      transactionId: transactionMap['id']?.toString() ?? '',
      totalMinor: _asInt(json['totalMinor']),
      currency: json['currency']?.toString() ?? 'BDT',
      items: items,
      subtotalMinor: json['subtotalMinor'] == null
          ? null
          : _asInt(json['subtotalMinor']),
      discountMinor: json['discountMinor'] == null
          ? 0
          : _asInt(json['discountMinor']),
      score: json['score'] == null ? null : _asInt(json['score']),
      paymentMethod: transactionMap['paymentMethod']?.toString(),
      reference: transactionMap['reference']?.toString(),
      smsId: transactionMap['smsId']?.toString(),
      cashMinor: cashTransaction?.amountMinor ?? _asInt(json['cashMinor']),
      cashTransaction: cashTransaction,
    );
  }

  final String transactionId;

  /// What was actually collected (the list-price bill minus any discount).
  final int totalMinor;

  final String currency;
  final List<SaleReceiptItem> items;

  /// The list-price bill before the shopkeeper's round-off/discount.
  final int? subtotalMinor;

  /// The amount knocked off to reach [totalMinor].
  final int discountMinor;

  /// The bill the catalogue prices add up to.
  int get billMinor => subtotalMinor ?? totalMinor + discountMinor;

  /// True when the shopkeeper rounded the bill down or gave a discount.
  bool get hasDiscount => discountMinor > 0;

  /// The credit score after the sale, when the server could recompute it.
  final int? score;

  /// cash | bkash | nagad | rocket | upay | upi | other.
  final String? paymentMethod;

  /// Mobile-money TrxID, when the payment was matched to an SMS.
  final String? reference;

  /// SMS row id, when this sale merged into an existing payment message.
  final String? smsId;

  /// The part of [totalMinor] the customer handed over in cash, when a mobile
  /// money message only covered the rest (bKash ৳30 + cash ৳10).
  final int cashMinor;

  /// The ledger row for the cash part, when the server booked one.
  final Transaction? cashTransaction;

  bool get isSplit => cashMinor > 0;

  /// The part covered by the mobile-money payment.
  int get digitalMinor => cashMinor >= totalMinor ? 0 : totalMinor - cashMinor;

  String get paymentMethodLabel => switch (paymentMethod) {
    'cash' => 'Cash',
    'bkash' => 'bKash',
    'nagad' => 'Nagad',
    'rocket' => 'Rocket',
    'upay' => 'Upay',
    'upi' => 'UPI',
    'other' => 'Other',
    _ => 'Not recorded',
  };

  String get totalLabel => formatMinor(totalMinor, currency: currency);
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
