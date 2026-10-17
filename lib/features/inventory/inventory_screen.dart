import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../models/product.dart';
import '../../models/shop.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import 'inventory_controller.dart';
import 'product_form_sheet.dart';

/// Tab 1 - what the shop sells.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Shop? shop = ref.watch(activeShopProvider);
    final AsyncValue<List<Product>> products = ref.watch(productListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Inventory'),
            if (shop != null)
              Text(
                shop.shopName,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: <Widget>[
          if (shop != null)
            IconButton(
              tooltip: 'Scan a product',
              onPressed: () => ProductFormSheet.show(context, autoScan: true),
              icon: const Icon(Icons.photo_camera_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(productListProvider),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: shop == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                FloatingActionButton.extended(
                  heroTag: 'sell',
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.sell),
                  icon: const Icon(Icons.point_of_sale_rounded),
                  label: const Text('Sell'),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'add-product',
                  onPressed: () => ProductFormSheet.show(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add product'),
                ),
              ],
            ),
      body: shop == null
          ? const _NoShopView()
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(productListProvider);
                await ref.read(productListProvider.future);
              },
              child: AsyncSection<List<Product>>(
                value: products,
                loadingMessage: 'Loading your inventory',
                onRetry: () => ref.invalidate(productListProvider),
                builder: (List<Product> items) {
                  if (items.isEmpty) {
                    return ListView(
                      // Must scroll for pull-to-refresh to work on an empty list.
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.12,
                        ),
                        EmptyState(
                          icon: Icons.inventory_2_outlined,
                          title: 'Add your first product to get started',
                          message:
                              'Track what you sell and how much is left. '
                              'Your inventory value feeds into your credit profile.',
                          action: FilledButton.icon(
                            onPressed: () => ProductFormSheet.show(context),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add product'),
                          ),
                        ),
                      ],
                    );
                  }

                  final InventorySummary summary = InventorySummary.from(items);

                  return ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    // Extra bottom padding clears the stacked Sell / Add buttons.
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 168),
                    itemCount: items.length + 1,
                    separatorBuilder: (_, int index) =>
                        SizedBox(height: index == 0 ? 12 : 8),
                    itemBuilder: (BuildContext context, int index) {
                      if (index == 0) {
                        return _InventorySummaryCard(summary: summary);
                      }

                      final Product product = items[index - 1];
                      return _ProductTile(product: product);
                    },
                  );
                },
              ),
            ),
    );
  }
}

class _InventorySummaryCard extends StatelessWidget {
  const _InventorySummaryCard({required this.summary});

  final InventorySummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppCard(
      title: 'Stock at a glance',
      subtitle:
          '${summary.productCount} product${summary.productCount == 1 ? '' : 's'} tracked',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            formatMinor(summary.stockValueMinor),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: GreenBizTheme.inflow,
            ),
          ),
          Text(
            'total stock value',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (summary.outOfStockCount > 0 ||
              summary.lowStockCount > 0) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (summary.outOfStockCount > 0)
                  StatusChip(
                    label: '${summary.outOfStockCount} out of stock',
                    color: theme.colorScheme.error,
                    icon: Icons.error_outline_rounded,
                  ),
                if (summary.lowStockCount > 0)
                  StatusChip(
                    label: '${summary.lowStockCount} running low',
                    color: GreenBizTheme.scoreMedium,
                    icon: Icons.warning_amber_rounded,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color stockColor = product.isOutOfStock
        ? theme.colorScheme.error
        : product.isLowStock
        ? GreenBizTheme.scoreMedium
        : GreenBizTheme.inflow;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () =>
            Navigator.of(context)
                .pushNamed(AppRoutes.productDetail, arguments: product),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Container(
                height: 42,
                width: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      product.productName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      product.priceLabel(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    product.stockLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: stockColor,
                    ),
                  ),
                  Text(
                    'in stock',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the account has no shop at all.
///
/// Registration creates one automatically, so this is reachable only after the
/// user deletes every shop — which is exactly when they need a way back.
class _NoShopView extends StatelessWidget {
  const _NoShopView();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.storefront_outlined,
      title: 'No shop yet',
      message:
          'Create a shop in the Profile tab to start tracking inventory, '
          'payments, and your credit profile.',
      action: FilledButton(
        onPressed: () => Navigator.of(context).pushNamed(AppRoutes.home),
        child: const Text('Go to Profile'),
      ),
    );
  }
}
