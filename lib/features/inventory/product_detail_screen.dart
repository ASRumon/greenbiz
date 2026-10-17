import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../models/product.dart';
import '../../widgets/common.dart';
import 'inventory_controller.dart';
import 'product_form_sheet.dart';

/// Product detail: edit, adjust stock, or delete.
class ProductDetailScreen extends ConsumerStatefulWidget {
  const ProductDetailScreen({super.key, required this.product});

  final Product product;

  @override
  ConsumerState<ProductDetailScreen> createState() =>
      _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  /// Local copy, so an edit is reflected immediately without a round trip.
  late Product _product = widget.product;
  bool _isDeleting = false;

  Future<void> _edit() async {
    final bool? changed = await ProductFormSheet.show(
      context,
      existing: _product,
    );
    if (changed != true || !mounted) return;

    // Reload the fresh row so the screen shows what the server actually stored.
    final List<Product>? items = ref.read(productListProvider).value;
    if (items != null) {
      for (final Product candidate in items) {
        if (candidate.id == _product.id) {
          setState(() => _product = candidate);
          break;
        }
      }
    }
  }

  Future<void> _delete() async {
    final bool confirmed = await confirmDialog(
      context,
      title: 'Delete product?',
      message:
          'This removes "${_product.productName}" from your inventory. '
          'Transactions already recorded are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isDeleting = true);

    try {
      await ref.read(inventoryControllerProvider).deleteProduct(_product.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppMessage(context, 'Product deleted.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      showErrorMessage(context, error);
    }
  }

  /// Quick stock adjustment, so restocking does not require the full form.
  Future<void> _adjustStock(double delta) async {
    final double next = _product.stockQuantity + delta;
    if (next < 0) {
      showAppMessage(context, 'Stock cannot go below zero.', isError: true);
      return;
    }

    try {
      final Product updated = await ref
          .read(inventoryControllerProvider)
          .updateProduct(_product.id, stockQuantity: next);

      if (!mounted) return;
      setState(() => _product = updated);
      showAppMessage(
        context,
        'Stock updated to ${updated.stockLabel} ${updated.unit}.',
      );
    } catch (error) {
      if (!mounted) return;
      showErrorMessage(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Edit',
            onPressed: _isDeleting ? null : _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: _isDeleting ? null : _delete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _product.productName,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                StatusChip(
                  label: _product.isOutOfStock
                      ? 'Out of stock'
                      : _product.isLowStock
                      ? 'Running low'
                      : 'In stock',
                  color: _product.isOutOfStock
                      ? theme.colorScheme.error
                      : _product.isLowStock
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            title: 'Details',
            child: Column(
              children: <Widget>[
                DetailRow(
                  label: 'Unit price',
                  value: formatMinor(_product.unitPriceMinor),
                ),
                DetailRow(label: 'Sold by', value: _product.unit),
                DetailRow(
                  label: 'In stock',
                  value: '${_product.stockLabel} ${_product.unit}',
                  valueColor: _product.isOutOfStock
                      ? theme.colorScheme.error
                      : null,
                ),
                DetailRow(
                  label: 'Stock value',
                  value: formatMinor(_product.stockValueMinor),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            title: 'Quick restock',
            subtitle: 'Adjust the count without opening the full form',
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isDeleting ? null : () => _adjustStock(-1),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                    label: const Text('1'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isDeleting ? null : () => _adjustStock(1),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('1'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isDeleting ? null : () => _adjustStock(10),
                    child: const Text('+10'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_isDeleting)
            const LoadingView(message: 'Deleting')
          else
            OutlinedButton.icon(
              onPressed: _delete,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete this product'),
            ),
        ],
      ),
    );
  }
}
