import '../core/api_client.dart';
import '../models/product.dart';

class ProductService {
  ProductService(this._api);

  final ApiClient _api;

  Future<List<Product>> listForShop(String shopId) async {
    final json = await _api.get('/shops/$shopId/products');
    return asJsonList(json['products'])
        .map(Product.fromJson)
        .toList(growable: false);
  }

  Future<Product> create(
    String shopId, {
    required String productName,
    required String unit,
    required int unitPriceMinor,
    required double stockQuantity,
    String? id,
  }) async {
    final json = await _api.post(
      '/shops/$shopId/products',
      body: <String, dynamic>{
        'id': ?id,
        'productName': productName,
        'unit': unit,
        'unitPriceMinor': unitPriceMinor,
        'stockQuantity': stockQuantity,
      },
    );
    return Product.fromJson(_asMap(json['product']));
  }

  Future<Product> update(
    String productId, {
    String? productName,
    String? unit,
    int? unitPriceMinor,
    double? stockQuantity,
  }) async {
    final json = await _api.patch(
      '/products/$productId',
      body: <String, dynamic>{
        'productName': ?productName,
        'unit': ?unit,
        'unitPriceMinor': ?unitPriceMinor,
        'stockQuantity': ?stockQuantity,
      },
    );
    return Product.fromJson(_asMap(json['product']));
  }

  Future<void> delete(String productId) async {
    await _api.delete('/products/$productId');
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
