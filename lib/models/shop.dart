import '../core/api_client.dart';

/// A business location the owner keeps records for.
class Shop {
  const Shop({
    required this.id,
    required this.shopName,
    this.businessType,
    this.phone,
    this.address,
    this.createdAt,
  });

  factory Shop.fromJson(Map<String, dynamic> json) => Shop(
    id: json['id']?.toString() ?? '',
    shopName: json['shopName']?.toString() ?? 'Untitled shop',
    businessType: asString(json['businessType']),
    phone: asString(json['phone']),
    address: asString(json['address']),
    createdAt: asDateTime(json['createdAt']),
  );

  final String id;
  final String shopName;
  final String? businessType;
  final String? phone;
  final String? address;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'shopName': shopName,
    if (businessType != null) 'businessType': businessType,
    if (phone != null) 'phone': phone,
    if (address != null) 'address': address,
  };

  Shop copyWith({
    String? shopName,
    String? businessType,
    String? phone,
    String? address,
  }) => Shop(
    id: id,
    shopName: shopName ?? this.shopName,
    businessType: businessType ?? this.businessType,
    phone: phone ?? this.phone,
    address: address ?? this.address,
    createdAt: createdAt,
  );
}
