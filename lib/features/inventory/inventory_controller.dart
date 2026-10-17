import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/revision.dart';
import '../../models/product.dart';
import '../auth/auth_controller.dart';

/// Products for the active shop.
///
/// Watches [activeShopProvider], so switching shops in the Profile tab
/// automatically refetches — no manual invalidation anywhere.
final productListProvider = FutureProvider<List<Product>>((ref) async {
  // Re-read SQLite after a local write or a pull from the server.
  ref.watch(dataRevisionProvider);

  // Watch the id, not the Shop object: an auth refresh recreates the object
  // with the same id, and watching the object made the list reload for no
  // reason. Only an actual shop change should refetch.
  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return const <Product>[];

  return ref.watch(productServiceProvider).listForShop(shopId);
});

/// Header numbers for the Inventory tab, derived from the loaded list so they
/// can never disagree with what is on screen.
class InventorySummary {
  const InventorySummary({
    required this.productCount,
    required this.stockValueMinor,
    required this.outOfStockCount,
    required this.lowStockCount,
  });

  static const InventorySummary empty = InventorySummary(
    productCount: 0,
    stockValueMinor: 0,
    outOfStockCount: 0,
    lowStockCount: 0,
  );

  final int productCount;
  final int stockValueMinor;
  final int outOfStockCount;
  final int lowStockCount;

  factory InventorySummary.from(List<Product> products) {
    var stockValue = 0;
    var outOfStock = 0;
    var lowStock = 0;

    for (final product in products) {
      // Summed in minor units; the value is only divided for display.
      stockValue += product.stockValueMinor;
      if (product.isOutOfStock) {
        outOfStock++;
      } else if (product.isLowStock) {
        lowStock++;
      }
    }

    return InventorySummary(
      productCount: products.length,
      stockValueMinor: stockValue,
      outOfStockCount: outOfStock,
      lowStockCount: lowStock,
    );
  }
}

/// Writes for inventory. Reads go through [productListProvider].
class InventoryController {
  const InventoryController(this._ref);

  final Ref _ref;

  Future<Product> addProduct({
    required String productName,
    required String unit,
    required int unitPriceMinor,
    required double stockQuantity,
  }) async {
    final shop = _ref.read(activeShopProvider);
    if (shop == null) {
      throw StateError('Create a shop before adding products.');
    }

    final product = await _ref
        .read(productServiceProvider)
        .create(
          shop.id,
          productName: productName,
          unit: unit,
          unitPriceMinor: unitPriceMinor,
          stockQuantity: stockQuantity,
        );

    _ref.invalidate(productListProvider);
    return product;
  }

  Future<Product> updateProduct(
    String productId, {
    String? productName,
    String? unit,
    int? unitPriceMinor,
    double? stockQuantity,
  }) async {
    final product = await _ref
        .read(productServiceProvider)
        .update(
          productId,
          productName: productName,
          unit: unit,
          unitPriceMinor: unitPriceMinor,
          stockQuantity: stockQuantity,
        );

    _ref.invalidate(productListProvider);
    return product;
  }

  Future<void> deleteProduct(String productId) async {
    await _ref.read(productServiceProvider).delete(productId);
    _ref.invalidate(productListProvider);
  }
}

final inventoryControllerProvider = Provider<InventoryController>(
  (ref) => InventoryController(ref),
);
