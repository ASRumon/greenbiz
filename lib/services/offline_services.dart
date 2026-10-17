import 'dart:async';
import 'dart:convert';

import '../core/api_client.dart';
import '../core/ids.dart';
import '../core/local_db.dart';
import '../models/credit_profile.dart';
import '../models/live_sms_payment.dart';
import '../models/plan.dart';
import '../models/product.dart';
import '../models/sale.dart';
import '../models/transaction.dart';
import 'auth_service.dart';
import 'credit_service.dart';
import 'product_service.dart';
import 'sync_service.dart';
import 'transaction_service.dart';

/// Login is the one operation that still needs the network. Everything after it
/// opens from the local database, and the session is restored from cache when
/// the Worker cannot be reached.
class OfflineAuthService {
  OfflineAuthService(this._remote, this._local, this._sync);

  final AuthService _remote;
  final LocalDatabase _local;
  final SyncService _sync;

  Future<AuthSession> register({
    required String fullName,
    required String username,
    required String password,
    String? email,
    String? shopName,
    String? businessType,
  }) => _remote.register(
    fullName: fullName,
    username: username,
    password: password,
    email: email,
    shopName: shopName,
    businessType: businessType,
  );

  Future<AuthSession> login({
    required String username,
    required String password,
  }) => _remote.login(username: username, password: password);

  Future<AccountSnapshot> me() async {
    final CachedAccount? cached = await _local.loadAccount();

    // Opening the app with no signal must not wait for a socket timeout.
    if (!await _sync.isOnline() && cached != null) {
      return AccountSnapshot(user: cached.user, shops: cached.shops);
    }

    try {
      final AccountSnapshot snapshot = await _remote.me();
      await _local.saveAccount(snapshot.user, snapshot.shops);
      return snapshot;
    } on ApiException catch (error) {
      // An expired token must still sign the user out. A network failure must
      // not: the cached account is the whole point of offline-first.
      if (error.isUnauthorized) rethrow;
      if (cached == null) rethrow;
      return AccountSnapshot(user: cached.user, shops: cached.shops);
    }
  }

  Future<void> logout() async {
    await _remote.logout();
    await _local.clearAll();
  }
}

/// Inventory reads come from SQLite, writes go to SQLite and the outbox.
class OfflineProductService {
  OfflineProductService(this._remote, this._local, this._sync);

  final ProductService _remote;
  final LocalDatabase _local;
  final SyncService _sync;

  Future<List<Product>> listForShop(String shopId) async {
    final List<Product> cached = await _local.listProducts(shopId);
    if (cached.isNotEmpty) return cached;

    // First run for this shop: there is nothing to show from cache.
    if (!await _sync.isOnline()) return cached;

    try {
      final List<Product> remote = await _remote.listForShop(shopId);
      await _local.replaceProducts(shopId, remote);
      return remote;
    } on ApiException catch (error) {
      if (error.isNetworkFailure) return cached;
      rethrow;
    }
  }

  Future<Product> create(
    String shopId, {
    required String productName,
    required String unit,
    required int unitPriceMinor,
    required double stockQuantity,
  }) async {
    final Product product = Product(
      id: newUuid(),
      shopId: shopId,
      productName: productName,
      unit: unit,
      unitPriceMinor: unitPriceMinor,
      stockQuantity: stockQuantity,
      createdAt: DateTime.now(),
      isPending: true,
    );

    await _local.upsertProduct(product, syncState: 1);
    await _local.enqueue(
      type: 'product_create',
      entityId: product.id,
      shopId: shopId,
      payload: <String, dynamic>{
        'productName': product.productName,
        'unit': product.unit,
        'unitPriceMinor': product.unitPriceMinor,
        'stockQuantity': product.stockQuantity,
      },
    );
    _sync.kick();
    return product;
  }

  Future<Product> update(
    String productId, {
    String? productName,
    String? unit,
    int? unitPriceMinor,
    double? stockQuantity,
  }) async {
    final Product? existing = await _local.getProduct(productId);
    if (existing == null) {
      throw const ApiException(
        code: 'NOT_FOUND',
        message: 'That product is no longer in the local inventory.',
      );
    }

    final Product updated = existing.copyWith(
      productName: productName,
      unit: unit,
      unitPriceMinor: unitPriceMinor,
      stockQuantity: stockQuantity,
      isPending: true,
    );

    await _local.upsertProduct(updated, syncState: 1);
    await _local.enqueue(
      type: 'product_update',
      entityId: productId,
      shopId: existing.shopId,
      payload: <String, dynamic>{
        'productName': ?productName,
        'unit': ?unit,
        'unitPriceMinor': ?unitPriceMinor,
        'stockQuantity': ?stockQuantity,
      },
    );
    _sync.kick();
    return updated;
  }

  Future<void> delete(String productId) async {
    final Product? existing = await _local.getProduct(productId);
    await _local.deleteProduct(productId);
    await _local.enqueue(
      type: 'product_delete',
      entityId: productId,
      shopId: existing?.shopId,
      payload: const <String, dynamic>{},
    );
    _sync.kick();
  }
}

/// Payments (manual and SMS-imported) read from SQLite. Marking a transaction
/// business/personal is a local update plus an outbox entry.
class OfflineTransactionService {
  OfflineTransactionService(this._remote, this._local, this._sync);

  final TransactionService _remote;
  final LocalDatabase _local;
  final SyncService _sync;

  /// Ranges already fetched in the background this session. Without this a
  /// report for a genuinely empty month would refetch on every rebuild.
  final Set<String> _prefetchedRanges = <String>{};

  Future<TransactionPage> listForShop(
    String shopId, {
    DateTime? from,
    DateTime? to,
    String? direction,
    bool businessOnly = false,
    int limit = 200,
    int offset = 0,
    bool prefetchRemote = false,
  }) async {
    var rows = await _local.listTransactions(
      shopId,
      from: from,
      to: to,
      direction: direction,
      businessOnly: businessOnly,
      limit: limit,
      offset: offset,
    );

    if (prefetchRemote) {
      // A report must render from the cache immediately. Asking the server
      // first is what left the Finance tab on a spinner while two network
      // requests timed out. Refresh the range after the first frame instead.
      unawaited(
        _prefetchRange(
          shopId,
          from: from,
          to: to,
          direction: direction,
          businessOnly: businessOnly,
          limit: limit,
          offset: offset,
        ),
      );
    } else if (rows.isEmpty && await _sync.isOnline()) {
      // A list with nothing cached (e.g. first run) can afford to wait once.
      try {
        final TransactionPage page = await _remote.listForShop(
          shopId,
          from: from,
          to: to,
          direction: direction,
          businessOnly: businessOnly,
          limit: limit,
          offset: offset,
        );
        await _local.upsertRemoteTransactions(page.transactions);
        rows = page.transactions;
      } on ApiException catch (error) {
        if (!error.isNetworkFailure) rethrow;
      }
    }

    return TransactionPage(
      transactions: rows,
      totalInMinor: rows
          .where((Transaction tx) => tx.isInflow)
          .fold<int>(0, (int sum, Transaction tx) => sum + tx.amountMinor),
      totalOutMinor: rows
          .where((Transaction tx) => !tx.isInflow)
          .fold<int>(0, (int sum, Transaction tx) => sum + tx.amountMinor),
      currency: rows.isEmpty ? 'BDT' : rows.first.currency,
    );
  }

  /// Fetches one report range and caches it. Runs off the UI path.
  Future<void> _prefetchRange(
    String shopId, {
    DateTime? from,
    DateTime? to,
    String? direction,
    required bool businessOnly,
    required int limit,
    required int offset,
  }) async {
    final String key = <Object?>[
      shopId,
      from?.millisecondsSinceEpoch,
      to?.millisecondsSinceEpoch,
      direction,
      businessOnly,
      limit,
      offset,
    ].join('|');

    if (!_prefetchedRanges.add(key)) return;

    if (!await _sync.isOnline()) {
      _prefetchedRanges.remove(key);
      return;
    }

    try {
      final TransactionPage page = await _remote.listForShop(
        shopId,
        from: from,
        to: to,
        direction: direction,
        businessOnly: businessOnly,
        limit: limit,
        offset: offset,
      );
      await _local.upsertRemoteTransactions(page.transactions);

      // Rebuild the report with the rows that just arrived. The guard above
      // stops this from becoming a fetch loop for an empty range.
      _sync.onLocalChange?.call();
    } catch (_) {
      // Allow a later rebuild or pull-to-refresh to retry.
      _prefetchedRanges.remove(key);
    }
  }

  Future<TransactionPage> currentMonth(String shopId) {
    final DateTime now = DateTime.now();
    return listForShop(
      shopId,
      from: DateTime(now.year, now.month),
      to: now,
      limit: 500,
      businessOnly: true,
    );
  }

  Future<Transaction> create(
    String shopId, {
    required String direction,
    required int amountMinor,
    String? currency,
    String? counterparty,
    String? reference,
    DateTime? occurredAt,
    String? note,
    String? id,
    bool? isBusiness,
    String? paymentMethod,
  }) async {
    final Transaction transaction = Transaction(
      id: id ?? newUuid(),
      shopId: shopId,
      direction: direction,
      amountMinor: amountMinor,
      currency: currency ?? await _local.defaultCurrency(shopId),
      counterparty: counterparty,
      reference: reference,
      occurredAt: occurredAt ?? DateTime.now(),
      note: note,
      createdAt: DateTime.now(),
      isBusiness: isBusiness ?? true,
      paymentMethod: paymentMethod,
      syncState: 1,
    );

    await _local.upsertTransaction(transaction, syncState: 1);
    await _local.enqueue(
      type: 'transaction_create',
      entityId: transaction.id,
      shopId: shopId,
      payload: <String, dynamic>{
        'direction': transaction.direction,
        'amountMinor': transaction.amountMinor,
        'currency': transaction.currency,
        'counterparty': transaction.counterparty,
        'reference': transaction.reference,
        'occurredAt': transaction.occurredAt.millisecondsSinceEpoch,
        'note': transaction.note,
        'isBusiness': transaction.isBusiness,
        'paymentMethod': ?transaction.paymentMethod,
      },
    );
    _sync.kick();
    return transaction;
  }

  Future<Transaction> update(
    String transactionId, {
    String? direction,
    int? amountMinor,
    String? counterparty,
    String? reference,
    DateTime? occurredAt,
    String? note,
    bool? isBusiness,
    String? paymentMethod,
  }) async {
    final Transaction? existing = await _local.getTransaction(transactionId);
    if (existing == null) {
      throw const ApiException(
        code: 'NOT_FOUND',
        message: 'That transaction is no longer in the local ledger.',
      );
    }

    final Transaction updated = existing.copyWith(
      direction: direction,
      amountMinor: amountMinor,
      counterparty: counterparty,
      reference: reference,
      occurredAt: occurredAt,
      note: note,
      isBusiness: isBusiness,
      paymentMethod: paymentMethod,
      syncState: 1,
    );

    await _local.upsertTransaction(updated, syncState: 1);
    await _local.enqueue(
      type: 'transaction_update',
      entityId: transactionId,
      shopId: existing.shopId,
      payload: <String, dynamic>{
        'direction': ?direction,
        'amountMinor': ?amountMinor,
        'counterparty': ?counterparty,
        'reference': ?reference,
        if (occurredAt != null) 'occurredAt': occurredAt.millisecondsSinceEpoch,
        'note': ?note,
        'isBusiness': ?isBusiness,
      },
    );
    _sync.kick();
    return updated;
  }

  /// Flips a row between business and personal immediately, online or not.
  Future<Transaction?> setBusiness(
    String transactionId,
    bool isBusiness,
  ) async {
    final Transaction? existing = await _local.getTransaction(transactionId);
    if (existing == null) return null;
    if (existing.isBusiness == isBusiness) return existing;

    final Transaction updated = existing.copyWith(
      isBusiness: isBusiness,
      syncState: 1,
    );

    await _local.upsertTransaction(updated, syncState: 1);
    await _local.enqueue(
      type: 'transaction_update',
      entityId: transactionId,
      shopId: existing.shopId,
      payload: <String, dynamic>{'isBusiness': isBusiness},
    );
    _sync.kick();
    return updated;
  }

  Future<void> delete(String transactionId) async {
    final Transaction? existing = await _local.getTransaction(transactionId);
    await _local.deleteTransaction(transactionId);
    await _local.enqueue(
      type: 'transaction_delete',
      entityId: transactionId,
      shopId: existing?.shopId,
      payload: const <String, dynamic>{},
    );
    _sync.kick();
  }
}

/// A sale is recorded locally first: the receipt is built from local prices,
/// stock is reduced, and the whole thing is queued for the atomic server call.
class OfflineSaleService {
  OfflineSaleService(this._local, this._sync);

  final LocalDatabase _local;
  final SyncService _sync;

  Future<SaleReceipt> create(
    String shopId, {
    required List<SaleLine> lines,
    String? counterparty,
    DateTime? occurredAt,
    String? id,
    String paymentMethod = 'cash',
    String? paymentReference,
    String? smsId,
    LiveSmsPayment? liveSms,
  }) async {
    final DateTime now = DateTime.now();
    final String transactionId = id ?? newUuid();
    final String currency = await _local.defaultCurrency(shopId);

    final int totalMinor = lines.fold<int>(
      0,
      (int sum, SaleLine line) => sum + line.lineTotalMinor,
    );

    final String summary = lines
        .map(
          (SaleLine line) =>
              '${line.quantityLabel} ${line.product.unit} '
              '${line.product.productName}',
        )
        .join(', ');

    final String customer = (counterparty ?? '').trim().isEmpty
        ? 'Walk-in customer'
        : counterparty!.trim();

    final Transaction transaction = Transaction(
      id: transactionId,
      shopId: shopId,
      direction: 'in',
      amountMinor: totalMinor,
      currency: currency,
      counterparty: customer,
      reference: paymentReference,
      occurredAt: occurredAt ?? now,
      note: 'Sale: $summary'.length > 240
          ? 'Sale: $summary'.substring(0, 240)
          : 'Sale: $summary',
      createdAt: now,
      isBusiness: true,
      paymentMethod: paymentMethod,
      syncState: 1,
    );

    await _local.upsertTransaction(transaction, syncState: 1);

    for (final SaleLine line in lines) {
      await _local.adjustProductStock(line.product.id, -line.quantity);
    }

    await _local.enqueue(
      type: 'sale',
      entityId: transactionId,
      shopId: shopId,
      payload: <String, dynamic>{
        'items': <Map<String, dynamic>>[
          for (final SaleLine line in lines)
            <String, dynamic>{
              'productId': line.product.id,
              'quantity': line.quantity,
            },
        ],
        'counterparty': customer,
        'occurredAt': transaction.occurredAt.millisecondsSinceEpoch,
        'paymentMethod': paymentMethod,
        'reference': ?paymentReference,
        'smsId': ?smsId,
        'liveSms': ?liveSms?.toJson(),
      },
    );
    _sync.kick();

    return SaleReceipt(
      transactionId: transactionId,
      totalMinor: totalMinor,
      currency: currency,
      paymentMethod: paymentMethod,
      reference: paymentReference,
      smsId: smsId,
      items: <SaleReceiptItem>[
        for (final SaleLine line in lines)
          SaleReceiptItem(
            productId: line.product.id,
            productName: line.product.productName,
            unit: line.product.unit,
            quantity: line.quantity,
            unitPriceMinor: line.product.unitPriceMinor,
            lineTotalMinor: line.lineTotalMinor,
          ),
      ],
    );
  }
}

/// Credit scores and the plan directory are cached JSON from the server.
class OfflineCreditService {
  OfflineCreditService(this._api, this._local, this._sync);

  final ApiClient _api;
  final LocalDatabase _local;
  final SyncService _sync;

  /// When each remote read was last attempted. A burst of local revisions must
  /// not become a burst of identical HTTP requests.
  final Map<String, int> _lastFetchMs = <String, int>{};
  static const int _freshnessMs = 20 * 1000;

  bool _mayRefresh(String key) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int? last = _lastFetchMs[key];
    if (last != null && now - last < _freshnessMs) return false;
    _lastFetchMs[key] = now;
    return true;
  }

  Future<CreditProfile> get(String shopId) async {
    final Map<String, dynamic>? cached = await _local.readCreditJson(shopId);
    final CreditProfile? fallback = cached == null
        ? null
        : CreditProfile.fromJson(_asMap(cached['creditProfile']));

    if (!await _sync.isOnline()) {
      if (fallback != null) return fallback;
      throw _offline('Connect once to download your credit profile.');
    }

    // Render the last known profile now, then refresh it off the UI path. This
    // is what stops the Finance card flashing a spinner on every launch.
    if (fallback != null) {
      if (_mayRefresh('credit:$shopId')) {
        unawaited(_refreshCredit(shopId, cached!));
      }
      return fallback;
    }

    try {
      final Map<String, dynamic> json = await _api.get('/shops/$shopId/credit');
      await _local.saveCreditJson(shopId, jsonEncode(json));
      _lastFetchMs['credit:$shopId'] = DateTime.now().millisecondsSinceEpoch;
      return CreditProfile.fromJson(_asMap(json['creditProfile']));
    } on ApiException catch (error) {
      if (error.isNetworkFailure) {
        throw _offline('Connect once to download your credit profile.');
      }
      rethrow;
    }
  }

  Future<void> _refreshCredit(
    String shopId,
    Map<String, dynamic> previous,
  ) async {
    try {
      final Map<String, dynamic> json = await _api.get('/shops/$shopId/credit');
      final String next = jsonEncode(json);
      if (next == jsonEncode(previous)) return;
      await _local.saveCreditJson(shopId, next);
      _sync.onLocalChange?.call();
    } catch (_) {
      // Keep the cached profile; the next revision or manual refresh retries.
    }
  }

  Future<CreditProfile> recompute(String shopId) async {
    if (!await _sync.isOnline()) {
      throw _offline('Connect to the internet to recompute your score.');
    }

    final Map<String, dynamic> json = await _api.post(
      '/shops/$shopId/credit/recompute',
    );
    await _local.saveCreditJson(shopId, jsonEncode(json));
    _lastFetchMs['credit:$shopId'] = DateTime.now().millisecondsSinceEpoch;
    return CreditProfile.fromJson(_asMap(json['creditProfile']));
  }

  /// Matched plans, cached so the Finance card still renders the last ranking
  /// when the device is offline.
  Future<MatchResult> matchedPlans(
    String shopId, {
    String intent = 'loan',
    int? amountMinor,
  }) async {
    final String metaKey = 'matched_plans:$shopId:$intent';
    final String? cachedRaw = await _local.getMeta(metaKey);
    final MatchResult cached = _matchedPlansFromCache(cachedRaw);

    if (!await _sync.isOnline()) return cached;

    if (cachedRaw != null) {
      if (_mayRefresh('matched:$metaKey')) {
        unawaited(
          _refreshMatchedPlans(
            shopId,
            intent: intent,
            amountMinor: amountMinor,
            metaKey: metaKey,
            previousRaw: cachedRaw,
          ),
        );
      }
      return cached;
    }

    try {
      final Map<String, dynamic> json = await _api.get(
        '/shops/$shopId/matched-plans',
        query: <String, dynamic>{'intent': intent, 'amountMinor': ?amountMinor},
      );
      await _local.setMeta(metaKey, jsonEncode(json));
      _lastFetchMs['matched:$metaKey'] = DateTime.now().millisecondsSinceEpoch;
      return MatchResult.fromJson(json);
    } on ApiException {
      return cached;
    }
  }

  Future<void> _refreshMatchedPlans(
    String shopId, {
    required String intent,
    int? amountMinor,
    required String metaKey,
    required String previousRaw,
  }) async {
    try {
      final Map<String, dynamic> json = await _api.get(
        '/shops/$shopId/matched-plans',
        query: <String, dynamic>{'intent': intent, 'amountMinor': ?amountMinor},
      );
      final String next = jsonEncode(json);
      if (next == previousRaw) return;
      await _local.setMeta(metaKey, next);
      _sync.onLocalChange?.call();
    } catch (_) {
      // Keep the last ranking; the next revision or manual refresh retries.
    }
  }

  MatchResult _matchedPlansFromCache(String? cached) {
    if (cached == null) return MatchResult.empty;
    final Object? decoded = jsonDecode(cached);
    if (decoded is! Map) return MatchResult.empty;
    return MatchResult.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<List<Plan>> directory({String? serviceType}) async {
    final String? cached = await _local.getMeta('plans');

    if (!await _sync.isOnline()) {
      return _plansFromCache(cached, serviceType);
    }

    // The public catalogue changes rarely; show the cached copy immediately and
    // refresh it in the background at most once per freshness window.
    if (cached != null) {
      if (serviceType == null && _mayRefresh('plans')) {
        unawaited(_refreshPlans(cached));
      }
      return _plansFromCache(cached, serviceType);
    }

    try {
      final Map<String, dynamic> json = await _api.get(
        '/plans',
        query: <String, dynamic>{'limit': 100, 'serviceType': ?serviceType},
      );
      if (serviceType == null) {
        await _local.setMeta('plans', jsonEncode(json));
        _lastFetchMs['plans'] = DateTime.now().millisecondsSinceEpoch;
      }
      return asJsonList(json['plans'])
          .map(Plan.fromJson)
          .toList(growable: false);
    } on ApiException catch (error) {
      if (error.isNetworkFailure) return _plansFromCache(cached, serviceType);
      rethrow;
    }
  }

  Future<void> _refreshPlans(String previousRaw) async {
    try {
      final Map<String, dynamic> json = await _api.get(
        '/plans',
        query: const <String, dynamic>{'limit': 100},
      );
      final String next = jsonEncode(json);
      if (next == previousRaw) return;
      await _local.setMeta('plans', next);
      _sync.onLocalChange?.call();
    } catch (_) {
      // Keep the cached directory; the next launch retries.
    }
  }

  Future<List<Institution>> institutions() async {
    if (!await _sync.isOnline()) {
      throw _offline('Connect to the internet to load institutions.');
    }
    final Map<String, dynamic> json = await _api.get('/institutions');
    return asJsonList(json['institutions'])
        .map(Institution.fromJson)
        .toList(growable: false);
  }

  List<Plan> _plansFromCache(String? cached, String? serviceType) {
    if (cached == null) return const <Plan>[];

    final Object? decoded = jsonDecode(cached);
    if (decoded is! Map) return const <Plan>[];

    final List<Plan> plans = asJsonList(decoded['plans'])
        .map(Plan.fromJson)
        .toList(growable: false);

    if (serviceType == null) return plans;
    return plans
        .where((Plan plan) => plan.serviceType == serviceType)
        .toList(growable: false);
  }

  ApiException _offline(String message) =>
      ApiException(code: 'NETWORK_ERROR', message: message);

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
