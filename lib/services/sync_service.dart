import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/api_client.dart';
import '../core/local_db.dart';
import '../models/product.dart';
import '../models/transaction.dart';
import 'auth_service.dart';
import 'product_service.dart';
import 'sale_service.dart';
import 'transaction_service.dart';

/// What one sync attempt did.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.pulled = false,
    this.pending = 0,
    this.isOffline = false,
    this.unauthorized = false,
    this.errors = const <String>[],
  });

  final int pushed;
  final bool pulled;
  final int pending;
  final bool isOffline;
  final bool unauthorized;
  final List<String> errors;

  bool get changed => pushed > 0 || pulled;
}

/// Pushes queued writes and pulls fresh server state into [LocalDatabase].
///
/// Ordering matters: the outbox is drained first, so a pull cannot overwrite a
/// local edit that has not reached the server yet.
class SyncService {
  SyncService(this._api, this._local)
    : _auth = AuthService(_api),
      _products = ProductService(_api),
      _transactions = TransactionService(_api),
      _sales = SaleService(_api);

  final ApiClient _api;
  final LocalDatabase _local;

  final AuthService _auth;
  final ProductService _products;
  final TransactionService _transactions;
  final SaleService _sales;

  /// Set by the provider graph. Fired after a pull or a background prefetch.
  /// The revision layer debounces it, so a burst of writes refreshes once.
  void Function()? onLocalChange;

  /// Fired immediately after a user write is queued, so the screen updates in
  /// the next frame instead of waiting for the debounce.
  void Function()? onLocalWrite;

  Future<SyncReport>? _running;

  Future<bool> isOnline() async {
    try {
      final List<ConnectivityResult> results = await Connectivity()
          .checkConnectivity();
      return results.any(
        (ConnectivityResult r) => r != ConnectivityResult.none,
      );
    } catch (_) {
      // If the plugin cannot answer, let the HTTP layer decide.
      return true;
    }
  }

  /// Fire-and-forget sync. Used after a local write.
  void kick() {
    onLocalWrite?.call();
    unawaited(syncNow());
  }

  /// Runs at most one sync at a time; concurrent callers share the result.
  Future<SyncReport> syncNow() {
    return _running ??= _run().whenComplete(() {
      _running = null;
    });
  }

  Future<SyncReport> _run() async {
    if (!_api.hasSession) {
      return SyncReport(pending: await _local.pendingCount());
    }

    final int pendingBefore = await _local.pendingCount();
    if (!await isOnline()) {
      return SyncReport(pending: pendingBefore, isOffline: true);
    }

    final List<String> errors = <String>[];
    int pushed = 0;

    try {
      pushed = await _push(errors);
    } on ApiException catch (error) {
      if (error.isNetworkFailure || error.isUnauthorized) {
        // Some queued rows may have reached the server before the connection
        // dropped; their sync state changed locally, so refresh the screens.
        if (pushed > 0) onLocalChange?.call();
        return SyncReport(
          pushed: pushed,
          pending: await _local.pendingCount(),
          isOffline: error.isNetworkFailure,
          unauthorized: error.isUnauthorized,
          errors: <String>[error.message],
        );
      }
      errors.add(error.message);
    }

    bool pulled = false;
    try {
      await _pull();
      pulled = true;
      await _local.setMeta(
        'last_sync',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
    } on ApiException catch (error) {
      if (error.isNetworkFailure || error.isUnauthorized) {
        if (pushed > 0) onLocalChange?.call();
        return SyncReport(
          pushed: pushed,
          pending: await _local.pendingCount(),
          isOffline: error.isNetworkFailure,
          unauthorized: error.isUnauthorized,
          errors: <String>[error.message],
        );
      }
      errors.add(error.message);
    }

    onLocalChange?.call();
    return SyncReport(
      pushed: pushed,
      pulled: pulled,
      pending: await _local.pendingCount(),
      errors: errors,
    );
  }

  /* ------------------------------------------------------------------------ */
  /* Push                                                                      */
  /* ------------------------------------------------------------------------ */

  Future<int> _push(List<String> errors) async {
    final List<PendingOp> ops = await _local.pendingOps();
    int pushed = 0;

    for (final PendingOp op in ops) {
      try {
        await _apply(op);
        await _local.deleteOp(op.id);
        pushed++;
      } on ApiException catch (error) {
        final int? status = error.statusCode;
        final bool transient =
            error.isNetworkFailure ||
            error.isUnauthorized ||
            (status != null && status >= 500);

        if (transient) rethrow;

        // A 4xx will never succeed on retry (validation, missing row, stale
        // reference). Keep the row, mark it failed, and stop blocking the queue.
        await _markPermanentFailure(op);
        await _local.deleteOp(op.id);
        errors.add('${_label(op.type)}: ${error.message}');
      }
    }

    return pushed;
  }

  Future<void> _apply(PendingOp op) async {
    final Map<String, dynamic> payload = op.payload;
    final String? shopId = op.shopId;

    switch (op.type) {
      case 'product_create':
        final Product product = await _products.create(
          shopId!,
          id: op.entityId,
          productName: payload['productName'] as String,
          unit: payload['unit'] as String,
          unitPriceMinor: (payload['unitPriceMinor'] as num).toInt(),
          stockQuantity: (payload['stockQuantity'] as num).toDouble(),
        );
        await _local.upsertProduct(product, syncState: 0);

      case 'product_update':
        await _products.update(
          op.entityId,
          productName: payload['productName'] as String?,
          unit: payload['unit'] as String?,
          unitPriceMinor: (payload['unitPriceMinor'] as num?)?.toInt(),
          stockQuantity: (payload['stockQuantity'] as num?)?.toDouble(),
        );
        await _local.setProductSyncState(op.entityId, 0);

      case 'product_delete':
        await _ignoreMissing(() => _products.delete(op.entityId));

      case 'transaction_create':
        final Transaction created = await _transactions.create(
          shopId!,
          id: op.entityId,
          direction: payload['direction'] as String,
          amountMinor: (payload['amountMinor'] as num).toInt(),
          currency: payload['currency'] as String?,
          counterparty: payload['counterparty'] as String?,
          reference: payload['reference'] as String?,
          occurredAt: _date(payload['occurredAt']),
          note: payload['note'] as String?,
          isBusiness: payload['isBusiness'] as bool?,
          paymentMethod: payload['paymentMethod'] as String?,
        );
        await _local.upsertTransaction(created, syncState: 0);

      case 'transaction_update':
        final Transaction updated = await _transactions.update(
          op.entityId,
          direction: payload['direction'] as String?,
          amountMinor: (payload['amountMinor'] as num?)?.toInt(),
          counterparty: payload['counterparty'] as String?,
          reference: payload['reference'] as String?,
          occurredAt: _date(payload['occurredAt']),
          note: payload['note'] as String?,
          isBusiness: payload['isBusiness'] as bool?,
          paymentMethod: payload['paymentMethod'] as String?,
        );
        await _local.upsertTransaction(updated, syncState: 0);

      case 'transaction_delete':
        await _ignoreMissing(() => _transactions.delete(op.entityId));

      case 'sale':
        final List<({String productId, double quantity})> items =
            <({String productId, double quantity})>[
              for (final Object? raw in payload['items'] as List)
                if (raw is Map)
                  (
                    productId: raw['productId'] as String,
                    quantity: (raw['quantity'] as num).toDouble(),
                  ),
            ];

        final receipt = await _sales.createItems(
          shopId!,
          id: op.entityId,
          items: items,
          counterparty: payload['counterparty'] as String?,
          occurredAt: _date(payload['occurredAt']),
          paymentMethod: payload['paymentMethod'] as String?,
          reference: payload['reference'] as String?,
          smsId: payload['smsId'] as String?,
          liveSms: payload['liveSms'] is Map
              ? Map<String, dynamic>.from(payload['liveSms'] as Map)
              : null,
        );

        if (receipt.smsId != null && receipt.transactionId != op.entityId) {
          // The server merged the sale into the existing SMS payment row, so
          // the temporary sale row is not a real ledger entry.
          await _local.deleteTransaction(op.entityId);
          await _local.settleLinkedSmsPayment(
            smsId: receipt.smsId!,
            paymentMethod: receipt.paymentMethod,
            reference: receipt.reference,
          );
        } else {
          await _local.setTransactionSyncState(op.entityId, 0);
          await _local.updateTransactionPayment(
            op.entityId,
            paymentMethod: receipt.paymentMethod,
            reference: receipt.reference,
          );
        }
        for (final item in receipt.items) {
          if (item.remainingStock != null) {
            await _local.setProductStock(item.productId, item.remainingStock!);
          }
        }

      default:
        // Unknown op types are dropped by the caller after this returns.
        break;
    }
  }

  Future<void> _markPermanentFailure(PendingOp op) async {
    switch (op.type) {
      case 'product_create':
      case 'product_update':
        await _local.setProductSyncState(op.entityId, 2);

      case 'transaction_create':
      case 'transaction_update':
        await _local.setTransactionSyncState(op.entityId, 2);

      case 'sale':
        await _local.setTransactionSyncState(op.entityId, 2);
        // The server rejected the sale, so put the shelved quantity back.
        for (final Object? raw
            in (op.payload['items'] as List? ?? <Object>[])) {
          if (raw is! Map) continue;
          await _local.adjustProductStock(
            raw['productId'] as String,
            (raw['quantity'] as num).toDouble(),
          );
          await _local.setProductSyncState(raw['productId'] as String, 0);
        }

      default:
        break;
    }
  }

  Future<void> _ignoreMissing(Future<void> Function() call) async {
    try {
      await call();
    } on ApiException catch (error) {
      // Already deleted on the server, or never existed: the local intent is
      // satisfied either way.
      if (error.statusCode != 404) rethrow;
    }
  }

  /* ------------------------------------------------------------------------ */
  /* Pull                                                                      */
  /* ------------------------------------------------------------------------ */

  Future<void> _pull() async {
    final AccountSnapshot snapshot = await _auth.me();
    await _local.saveAccount(snapshot.user, snapshot.shops);

    for (final shop in snapshot.shops) {
      final List<Product> products = await _products.listForShop(shop.id);
      await _local.replaceProducts(shop.id, products);

      // Two years of a busy shop is still comfortably inside this page, and it
      // gives the offline Finance report enough history to compare periods.
      final page = await _transactions.listForShop(shop.id, limit: 2000);
      await _local.upsertRemoteTransactions(page.transactions);

      try {
        final Map<String, dynamic> credit = await _api.get(
          '/shops/${shop.id}/credit',
        );
        await _local.saveCreditJson(shop.id, jsonEncode(credit));
      } on ApiException catch (error) {
        if (error.isNetworkFailure || error.isUnauthorized) rethrow;
        // A shop with no profile yet is fine; products and payments still sync.
      }
    }

    try {
      final Map<String, dynamic> plans = await _api.get(
        '/plans',
        query: <String, dynamic>{'limit': 100},
      );
      await _local.setMeta('plans', jsonEncode(plans));
    } on ApiException catch (error) {
      if (error.isNetworkFailure || error.isUnauthorized) rethrow;
    }
  }

  DateTime? _date(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) {
      final int? millis = int.tryParse(value);
      if (millis != null) return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    return null;
  }

  String _label(String type) => switch (type) {
    'product_create' => 'New product',
    'product_update' => 'Product edit',
    'product_delete' => 'Product deletion',
    'transaction_create' => 'New payment',
    'transaction_update' => 'Payment edit',
    'transaction_delete' => 'Payment deletion',
    'sale' => 'Sale',
    _ => 'Change',
  };
}
