import '../core/api_client.dart';
import '../models/shop.dart';

class ShopService {
  ShopService(this._api);

  final ApiClient _api;

  Future<List<Shop>> list() async {
    final json = await _api.get('/shops');
    return asJsonList(json['shops']).map(Shop.fromJson).toList(growable: false);
  }

  Future<Shop> create({
    required String shopName,
    String? businessType,
    String? phone,
    String? address,
  }) async {
    final json = await _api.post(
      '/shops',
      body: <String, dynamic>{
        'shopName': shopName,
        if (businessType != null && businessType.isNotEmpty)
          'businessType': businessType,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (address != null && address.isNotEmpty) 'address': address,
      },
    );
    return Shop.fromJson(_asMap(json['shop']));
  }

  Future<Shop> get(String shopId) async {
    final json = await _api.get('/shops/$shopId');
    return Shop.fromJson(_asMap(json['shop']));
  }

  Future<Shop> update(
    String shopId, {
    String? shopName,
    String? businessType,
    String? phone,
    String? address,
  }) async {
    final json = await _api.patch(
      '/shops/$shopId',
      body: <String, dynamic>{
        'shopName': ?shopName,
        'businessType': ?businessType,
        'phone': ?phone,
        'address': ?address,
      },
    );
    return Shop.fromJson(_asMap(json['shop']));
  }

  Future<void> delete(String shopId) async {
    await _api.delete('/shops/$shopId');
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
