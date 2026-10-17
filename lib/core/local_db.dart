import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../models/product.dart';
import '../models/shop.dart';
import '../models/transaction.dart';
import '../models/user.dart';

/// One queued write that the server has not acknowledged yet.
class PendingOp {
  const PendingOp({
    required this.id,
    required this.type,
    required this.entityId,
    required this.payload,
    this.shopId,
    this.attempts = 0,
  });

  factory PendingOp.fromRow(Map<String, Object?> row) => PendingOp(
    id: row['id'] as int,
    type: row['type'] as String,
    entityId: row['entity_id'] as String,
    shopId: row['shop_id'] as String?,
    payload: row['payload'] is String
        ? Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map)
        : <String, dynamic>{},
    attempts: (row['attempts'] as int?) ?? 0,
  );

  final int id;

  /// product_create | product_update | product_delete
  /// transaction_create | transaction_update | transaction_delete | sale
  final String type;
  final String entityId;
  final String? shopId;
  final Map<String, dynamic> payload;
  final int attempts;
}

/// The account as it was last seen from the server.
typedef CachedAccount = ({User user, List<Shop> shops});

/// The app's offline source of truth.
///
/// Every read in the UI comes from here. The server is a sync target, not a
/// dependency: after the first sign-in the app opens, navigates, records sales
/// and edits inventory with no network at all.
///
/// `sync_state` is per row: 0 = synced, 1 = waiting to upload, 2 = upload
/// failed (the row is kept and shown, so nothing silently disappears).
class LocalDatabase {
  LocalDatabase._(this._db);

  static const String fileName = 'greenbiz_offline.db';

  final Database _db;

  static Future<LocalDatabase> open({String? path}) async {
    final String databasePath =
        path ?? p.join(await getDatabasesPath(), fileName);

    final Database db = await openDatabase(
      databasePath,
      version: 3,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE user_cache (
            id TEXT PRIMARY KEY,
            full_name TEXT NOT NULL,
            username TEXT NOT NULL,
            email TEXT,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE shop_cache (
            id TEXT PRIMARY KEY,
            shop_name TEXT NOT NULL,
            business_type TEXT,
            phone TEXT,
            address TEXT,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE product_cache (
            id TEXT PRIMARY KEY,
            shop_id TEXT NOT NULL,
            product_name TEXT NOT NULL,
            unit TEXT NOT NULL,
            unit_price_minor INTEGER NOT NULL,
            stock_quantity REAL NOT NULL,
            created_at INTEGER,
            sync_state INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX product_cache_shop_idx ON product_cache (shop_id)',
        );
        await db.execute('''
          CREATE TABLE transaction_cache (
            id TEXT PRIMARY KEY,
            shop_id TEXT NOT NULL,
            sms_id TEXT,
            direction TEXT NOT NULL,
            amount_minor INTEGER NOT NULL,
            currency TEXT NOT NULL,
            counterparty TEXT,
            reference TEXT,
            occurred_at INTEGER NOT NULL,
            note TEXT,
            is_business INTEGER NOT NULL DEFAULT 1,
            payment_method TEXT,
            sms_sender TEXT,
            sms_body TEXT,
            created_at INTEGER,
            sync_state INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX transaction_cache_shop_occurred_idx '
          'ON transaction_cache (shop_id, occurred_at)',
        );
        await db.execute('''
          CREATE TABLE credit_cache (
            shop_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            shop_id TEXT,
            payload TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE transaction_cache ADD COLUMN payment_method TEXT',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE transaction_cache ADD COLUMN sms_sender TEXT',
          );
          await db.execute(
            'ALTER TABLE transaction_cache ADD COLUMN sms_body TEXT',
          );
        }
      },
    );

    return LocalDatabase._(db);
  }

  /* ------------------------------------------------------------------------ */
  /* Account                                                                  */
  /* ------------------------------------------------------------------------ */

  Future<void> saveAccount(User user, List<Shop> shops) async {
    await _db.transaction((txn) async {
      await txn.delete('user_cache');
      await txn.insert('user_cache', <String, Object?>{
        'id': user.id,
        'full_name': user.fullName,
        'username': user.username,
        'email': user.email,
        'created_at': user.createdAt?.millisecondsSinceEpoch,
      });

      final List<String> shopIds = shops
          .map((Shop shop) => shop.id)
          .toList(growable: false);

      if (shopIds.isEmpty) {
        await txn.delete('shop_cache');
        await txn.delete('product_cache');
        await txn.delete('transaction_cache');
        await txn.delete('credit_cache');
        return;
      }

      final String placeholders = List<String>.filled(
        shopIds.length,
        '?',
      ).join(',');

      await txn.delete(
        'shop_cache',
        where: 'id NOT IN ($placeholders)',
        whereArgs: shopIds,
      );
      await txn.delete(
        'product_cache',
        where: 'shop_id NOT IN ($placeholders)',
        whereArgs: shopIds,
      );
      await txn.delete(
        'transaction_cache',
        where: 'shop_id NOT IN ($placeholders)',
        whereArgs: shopIds,
      );
      await txn.delete(
        'credit_cache',
        where: 'shop_id NOT IN ($placeholders)',
        whereArgs: shopIds,
      );

      for (final Shop shop in shops) {
        await txn.insert('shop_cache', <String, Object?>{
          'id': shop.id,
          'shop_name': shop.shopName,
          'business_type': shop.businessType,
          'phone': shop.phone,
          'address': shop.address,
          'created_at': shop.createdAt?.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<CachedAccount?> loadAccount() async {
    final List<Map<String, Object?>> userRows = await _db.query(
      'user_cache',
      limit: 1,
    );
    if (userRows.isEmpty) return null;

    final Map<String, Object?> row = userRows.first;
    final List<Map<String, Object?>> shopRows = await _db.query(
      'shop_cache',
      orderBy: 'created_at ASC',
    );

    return (
      user: User(
        id: row['id'] as String,
        fullName: row['full_name'] as String,
        username: row['username'] as String,
        email: row['email'] as String?,
        createdAt: _date(row['created_at']),
      ),
      shops: shopRows
          .map(
            (Map<String, Object?> shop) => Shop(
              id: shop['id'] as String,
              shopName: shop['shop_name'] as String,
              businessType: shop['business_type'] as String?,
              phone: shop['phone'] as String?,
              address: shop['address'] as String?,
              createdAt: _date(shop['created_at']),
            ),
          )
          .toList(growable: false),
    );
  }

  /* ------------------------------------------------------------------------ */
  /* Products                                                                 */
  /* ------------------------------------------------------------------------ */

  Future<void> replaceProducts(String shopId, List<Product> products) async {
    await _db.transaction((txn) async {
      final List<Map<String, Object?>> pending = await txn.query(
        'product_cache',
        columns: <String>['id'],
        where: 'shop_id = ? AND sync_state <> 0',
        whereArgs: <Object?>[shopId],
      );
      final Set<String> keep = pending
          .map((Map<String, Object?> row) => row['id'] as String)
          .toSet();

      await txn.delete(
        'product_cache',
        where: 'shop_id = ? AND sync_state = 0',
        whereArgs: <Object?>[shopId],
      );

      for (final Product product in products) {
        if (keep.contains(product.id)) continue;
        await txn.insert(
          'product_cache',
          _productRow(product, syncState: 0),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<Product>> listProducts(String shopId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'product_cache',
      where: 'shop_id = ?',
      whereArgs: <Object?>[shopId],
      orderBy: 'product_name ASC',
    );
    return rows.map(_productFromRow).toList(growable: false);
  }

  Future<Product?> getProduct(String productId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'product_cache',
      where: 'id = ?',
      whereArgs: <Object?>[productId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _productFromRow(rows.first);
  }

  Future<void> upsertProduct(Product product, {required int syncState}) async {
    await _db.insert(
      'product_cache',
      _productRow(product, syncState: syncState),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteProduct(String productId) async {
    await _db.delete(
      'product_cache',
      where: 'id = ?',
      whereArgs: <Object?>[productId],
    );
  }

  Future<void> setProductSyncState(String productId, int syncState) async {
    await _db.update(
      'product_cache',
      <String, Object?>{'sync_state': syncState},
      where: 'id = ?',
      whereArgs: <Object?>[productId],
    );
  }

  /// Applies a stock change locally (used by an offline sale).
  Future<void> adjustProductStock(String productId, double delta) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'product_cache',
      columns: <String>['stock_quantity'],
      where: 'id = ?',
      whereArgs: <Object?>[productId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final double current = ((rows.first['stock_quantity'] as num?) ?? 0)
        .toDouble();
    final double next = math.max(0, current + delta);

    await _db.update(
      'product_cache',
      <String, Object?>{'stock_quantity': next, 'sync_state': 1},
      where: 'id = ?',
      whereArgs: <Object?>[productId],
    );
  }

  Future<void> setProductStock(String productId, double stock) async {
    await _db.update(
      'product_cache',
      <String, Object?>{'stock_quantity': stock, 'sync_state': 0},
      where: 'id = ?',
      whereArgs: <Object?>[productId],
    );
  }

  /* ------------------------------------------------------------------------ */
  /* Transactions                                                             */
  /* ------------------------------------------------------------------------ */

  /// Inserts/updates rows fetched from the server, without clobbering a local
  /// edit that has not been uploaded yet.
  Future<void> upsertRemoteTransactions(List<Transaction> transactions) async {
    await _db.transaction((txn) async {
      for (final Transaction transaction in transactions) {
        final List<Map<String, Object?>> existing = await txn.query(
          'transaction_cache',
          columns: <String>['sync_state'],
          where: 'id = ?',
          whereArgs: <Object?>[transaction.id],
          limit: 1,
        );
        if (existing.isNotEmpty &&
            ((existing.first['sync_state'] as int?) ?? 0) != 0) {
          continue;
        }

        await txn.insert(
          'transaction_cache',
          _transactionRow(transaction, syncState: 0),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<Transaction>> listTransactions(
    String shopId, {
    DateTime? from,
    DateTime? to,
    String? direction,
    bool businessOnly = false,
    int limit = 200,
    int offset = 0,
  }) async {
    final List<String> where = <String>['shop_id = ?'];
    final List<Object?> args = <Object?>[shopId];

    if (from != null) {
      where.add('occurred_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('occurred_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    if (direction != null) {
      where.add('direction = ?');
      args.add(direction);
    }
    if (businessOnly) where.add('is_business = 1');

    final List<Map<String, Object?>> rows = await _db.query(
      'transaction_cache',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'occurred_at DESC',
      limit: limit,
      offset: offset,
    );

    return rows.map(_transactionFromRow).toList(growable: false);
  }

  Future<Transaction?> getTransaction(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'transaction_cache',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _transactionFromRow(rows.first);
  }

  Future<void> upsertTransaction(
    Transaction transaction, {
    required int syncState,
  }) async {
    await _db.insert(
      'transaction_cache',
      _transactionRow(transaction, syncState: syncState),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteTransaction(String id) async {
    await _db.delete(
      'transaction_cache',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> setTransactionSyncState(String id, int syncState) async {
    await _db.update(
      'transaction_cache',
      <String, Object?>{'sync_state': syncState},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> updateTransactionPayment(
    String id, {
    String? paymentMethod,
    String? reference,
  }) async {
    final Map<String, Object?> values = <String, Object?>{};
    if (paymentMethod != null) values['payment_method'] = paymentMethod;
    if (reference != null) values['reference'] = reference;
    if (values.isEmpty) return;

    await _db.update(
      'transaction_cache',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Marks the SMS row that a sale merged into as synced and updates its
  /// payment metadata. The temporary sale row is deleted by the caller.
  Future<void> settleLinkedSmsPayment({
    required String smsId,
    String? paymentMethod,
    String? reference,
  }) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'transaction_cache',
      columns: <String>['id'],
      where: 'sms_id = ?',
      whereArgs: <Object?>[smsId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final String id = rows.first['id'] as String;
    final Map<String, Object?> values = <String, Object?>{'sync_state': 0};
    if (paymentMethod != null) values['payment_method'] = paymentMethod;
    if (reference != null) values['reference'] = reference;

    await _db.update(
      'transaction_cache',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<String> defaultCurrency(String shopId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'transaction_cache',
      columns: <String>['currency'],
      where: 'shop_id = ?',
      whereArgs: <Object?>[shopId],
      orderBy: 'occurred_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return 'BDT';
    return (rows.first['currency'] as String?) ?? 'BDT';
  }

  /* ------------------------------------------------------------------------ */
  /* Credit profile and plans                                                 */
  /* ------------------------------------------------------------------------ */

  Future<void> saveCreditJson(String shopId, String payload) async {
    await _db.insert('credit_cache', <String, Object?>{
      'shop_id': shopId,
      'payload': payload,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> readCreditJson(String shopId) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'credit_cache',
      where: 'shop_id = ?',
      whereArgs: <Object?>[shopId],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final String payload = rows.first['payload'] as String;
    final Object? decoded = jsonDecode(payload);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /* ------------------------------------------------------------------------ */
  /* Outbox and metadata                                                      */
  /* ------------------------------------------------------------------------ */

  Future<int> enqueue({
    required String type,
    required String entityId,
    required Map<String, dynamic> payload,
    String? shopId,
  }) => _db.insert('outbox', <String, Object?>{
    'type': type,
    'entity_id': entityId,
    'shop_id': shopId,
    'payload': jsonEncode(payload),
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });

  Future<List<PendingOp>> pendingOps() async {
    final List<Map<String, Object?>> rows = await _db.query(
      'outbox',
      orderBy: 'id ASC',
    );
    return rows.map(PendingOp.fromRow).toList(growable: false);
  }

  Future<void> deleteOp(int id) async {
    await _db.delete('outbox', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> bumpAttempts(int id) async {
    await _db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1 WHERE id = ?',
      <Object?>[id],
    );
  }

  Future<int> pendingCount() async {
    final int? count = Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM outbox'),
    );
    return count ?? 0;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert('meta', <String, Object?>{
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getMeta(String key) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Removes everything belonging to the signed-in account. Called on logout
  /// so the next user of the phone cannot read the previous owner's ledger.
  Future<void> clearAll() async {
    await _db.transaction((txn) async {
      for (final String table in <String>[
        'user_cache',
        'shop_cache',
        'product_cache',
        'transaction_cache',
        'credit_cache',
        'outbox',
        'meta',
      ]) {
        await txn.delete(table);
      }
    });
  }

  /* ------------------------------------------------------------------------ */
  /* Row mapping                                                              */
  /* ------------------------------------------------------------------------ */

  Map<String, Object?> _productRow(Product product, {required int syncState}) =>
      <String, Object?>{
        'id': product.id,
        'shop_id': product.shopId,
        'product_name': product.productName,
        'unit': product.unit,
        'unit_price_minor': product.unitPriceMinor,
        'stock_quantity': product.stockQuantity,
        'created_at': product.createdAt?.millisecondsSinceEpoch,
        'sync_state': syncState,
      };

  Product _productFromRow(Map<String, Object?> row) => Product(
    id: row['id'] as String,
    shopId: row['shop_id'] as String,
    productName: row['product_name'] as String,
    unit: row['unit'] as String,
    unitPriceMinor: (row['unit_price_minor'] as num).toInt(),
    stockQuantity: ((row['stock_quantity'] as num?) ?? 0).toDouble(),
    createdAt: _date(row['created_at']),
    isPending: ((row['sync_state'] as int?) ?? 0) != 0,
  );

  Map<String, Object?> _transactionRow(
    Transaction transaction, {
    required int syncState,
  }) => <String, Object?>{
    'id': transaction.id,
    'shop_id': transaction.shopId,
    'sms_id': transaction.smsId,
    'direction': transaction.direction,
    'amount_minor': transaction.amountMinor,
    'currency': transaction.currency,
    'counterparty': transaction.counterparty,
    'reference': transaction.reference,
    'occurred_at': transaction.occurredAt.millisecondsSinceEpoch,
    'note': transaction.note,
    'is_business': transaction.isBusiness ? 1 : 0,
    'payment_method': transaction.paymentMethod,
    'sms_sender': transaction.smsSender,
    'sms_body': transaction.smsBody,
    'created_at': transaction.createdAt?.millisecondsSinceEpoch,
    'sync_state': syncState,
  };

  Transaction _transactionFromRow(Map<String, Object?> row) => Transaction(
    id: row['id'] as String,
    shopId: row['shop_id'] as String,
    smsId: row['sms_id'] as String?,
    direction: row['direction'] as String,
    amountMinor: (row['amount_minor'] as num).toInt(),
    currency: (row['currency'] as String?) ?? 'BDT',
    counterparty: row['counterparty'] as String?,
    reference: row['reference'] as String?,
    occurredAt:
        _date(row['occurred_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    note: row['note'] as String?,
    createdAt: _date(row['created_at']),
    isBusiness: ((row['is_business'] as int?) ?? 1) != 0,
    paymentMethod: row['payment_method'] as String?,
    smsSender: row['sms_sender'] as String?,
    smsBody: row['sms_body'] as String?,
    syncState: (row['sync_state'] as int?) ?? 0,
  );

  DateTime? _date(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }
}
