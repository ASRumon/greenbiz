import '../core/api_client.dart';
import '../models/transaction.dart';

class TransactionService {
  TransactionService(this._api);

  final ApiClient _api;

  /// Lists transactions for a shop within an optional range.
  ///
  /// Timestamps are sent as Unix milliseconds, matching the server's INTEGER
  /// columns — no date-string parsing on either side.
  Future<TransactionPage> listForShop(
    String shopId, {
    DateTime? from,
    DateTime? to,
    String? direction,
    bool businessOnly = false,
    int limit = 200,
    int offset = 0,
  }) async {
    final query = <String, dynamic>{'limit': limit, 'offset': offset};
    if (from != null) query['from'] = from.millisecondsSinceEpoch;
    if (to != null) query['to'] = to.millisecondsSinceEpoch;
    if (direction != null) query['direction'] = direction;
    if (businessOnly) query['businessOnly'] = 'true';

    final json = await _api.get('/shops/$shopId/transactions', query: query);
    return TransactionPage.fromJson(json);
  }

  /// Totals for the current calendar month, for the cash-flow card.
  ///
  /// Business rows only: personal spending must not inflate or deflate the
  /// figures that feed the credit score.
  Future<TransactionPage> currentMonth(String shopId) {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month);
    return listForShop(
      shopId,
      from: startOfMonth,
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
    final json = await _api.post(
      '/shops/$shopId/transactions',
      body: <String, dynamic>{
        'id': ?id,
        'direction': direction,
        'amountMinor': amountMinor,
        'currency': ?currency,
        if (counterparty != null && counterparty.isNotEmpty)
          'counterparty': counterparty,
        if (reference != null && reference.isNotEmpty) 'reference': reference,
        if (occurredAt != null) 'occurredAt': occurredAt.millisecondsSinceEpoch,
        if (note != null && note.isNotEmpty) 'note': note,
        'isBusiness': ?isBusiness,
        'paymentMethod': ?paymentMethod,
      },
    );
    return Transaction.fromJson(_asMap(json['transaction']));
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
    final json = await _api.patch(
      '/transactions/$transactionId',
      body: <String, dynamic>{
        'direction': ?direction,
        'amountMinor': ?amountMinor,
        'counterparty': ?counterparty,
        'reference': ?reference,
        if (occurredAt != null) 'occurredAt': occurredAt.millisecondsSinceEpoch,
        'note': ?note,
        'isBusiness': ?isBusiness,
        'paymentMethod': ?paymentMethod,
      },
    );
    return Transaction.fromJson(_asMap(json['transaction']));
  }

  Future<void> delete(String transactionId) async {
    await _api.delete('/transactions/$transactionId');
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
