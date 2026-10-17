import '../core/money.dart';
import 'product.dart';

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

/// "3" for 3.0, "2.5" for 2.50 — how a shopkeeper writes a quantity.
String formatQuantity(double quantity) {
  if (quantity == quantity.roundToDouble()) return quantity.toInt().toString();
  return quantity.toStringAsFixed(2);
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
    this.score,
    this.paymentMethod,
    this.reference,
    this.smsId,
  });

  factory SaleReceipt.fromJson(Map<String, dynamic> json) {
    final transaction = json['transaction'];
    final transactionMap = transaction is Map
        ? Map<String, dynamic>.from(transaction)
        : const <String, dynamic>{};

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
      score: json['score'] == null ? null : _asInt(json['score']),
      paymentMethod: transactionMap['paymentMethod']?.toString(),
      reference: transactionMap['reference']?.toString(),
      smsId: transactionMap['smsId']?.toString(),
    );
  }

  final String transactionId;
  final int totalMinor;
  final String currency;
  final List<SaleReceiptItem> items;

  /// The credit score after the sale, when the server could recompute it.
  final int? score;

  /// cash | bkash | nagad | rocket | upay | upi | other.
  final String? paymentMethod;

  /// Mobile-money TrxID, when the payment was matched to an SMS.
  final String? reference;

  /// SMS row id, when this sale merged into an existing payment message.
  final String? smsId;

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
