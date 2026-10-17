import '../core/api_client.dart';
import '../core/money.dart';

/// A stock item.
///
/// [unitPriceMinor] is an integer in minor units (poisha / paisa). It is never a
/// double: `0.1 + 0.2` problems become wrong money in a ledger.
class Product {
  const Product({
    required this.id,
    required this.shopId,
    required this.productName,
    required this.unit,
    required this.unitPriceMinor,
    required this.stockQuantity,
    this.createdAt,
    this.isPending = false,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    id: json['id']?.toString() ?? '',
    shopId: json['shopId']?.toString() ?? '',
    productName: json['productName']?.toString() ?? '',
    unit: json['unit']?.toString() ?? 'unit',
    unitPriceMinor: asInt(json['unitPriceMinor']),
    stockQuantity: asDouble(json['stockQuantity']),
    createdAt: asDateTime(json['createdAt']),
  );

  final String id;
  final String shopId;
  final String productName;
  final String unit;
  final int unitPriceMinor;

  /// REAL on the server: stock supports fractional units (2.5 kg of rice).
  final double stockQuantity;
  final DateTime? createdAt;

  /// Local-only: created or edited on this device and not yet synced.
  final bool isPending;

  Product copyWith({
    String? productName,
    String? unit,
    int? unitPriceMinor,
    double? stockQuantity,
    bool? isPending,
  }) => Product(
    id: id,
    shopId: shopId,
    productName: productName ?? this.productName,
    unit: unit ?? this.unit,
    unitPriceMinor: unitPriceMinor ?? this.unitPriceMinor,
    stockQuantity: stockQuantity ?? this.stockQuantity,
    createdAt: createdAt,
    isPending: isPending ?? this.isPending,
  );

  bool get isOutOfStock => stockQuantity <= 0;
  bool get isLowStock => stockQuantity > 0 && stockQuantity <= 5;

  /// Stock value in minor units, rounded to whole minor units.
  int get stockValueMinor => (unitPriceMinor * stockQuantity).round();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'productName': productName,
    'unit': unit,
    'unitPriceMinor': unitPriceMinor,
    'stockQuantity': stockQuantity,
  };

  /// Quantity for display: "24" rather than "24.0", but "2.5" stays "2.5".
  String get stockLabel {
    if (stockQuantity == stockQuantity.roundToDouble()) {
      return stockQuantity.toInt().toString();
    }
    return stockQuantity.toStringAsFixed(2);
  }

  String priceLabel({String currency = 'BDT'}) =>
      '${formatMinor(unitPriceMinor, currency: currency)} / $unit';
}
