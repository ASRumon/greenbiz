import '../core/api_client.dart';
import '../models/sale.dart';

/// Writes a completed sale through the server's atomic sale endpoint.
///
/// The server records one inflow transaction and decrements every product in a
/// single D1 batch, so the ledger and the stock can never disagree.
class SaleService {
  SaleService(this._api);

  final ApiClient _api;

  Future<SaleReceipt> create(
    String shopId, {
    required List<SaleLine> lines,
    String? counterparty,
    DateTime? occurredAt,
    String? id,
    String? paymentMethod,
    String? reference,
    String? smsId,
    Map<String, dynamic>? liveSms,
  }) => createItems(
    shopId,
    items: <({String productId, double quantity})>[
      for (final SaleLine line in lines)
        (productId: line.product.id, quantity: line.quantity),
    ],
    counterparty: counterparty,
    occurredAt: occurredAt,
    id: id,
    paymentMethod: paymentMethod,
    reference: reference,
    smsId: smsId,
    liveSms: liveSms,
  );

  /// Raw-item form used by the sync engine, which holds ids rather than
  /// hydrated products.
  Future<SaleReceipt> createItems(
    String shopId, {
    required List<({String productId, double quantity})> items,
    String? counterparty,
    DateTime? occurredAt,
    String? id,
    String? paymentMethod,
    String? reference,
    String? smsId,
    Map<String, dynamic>? liveSms,
  }) async {
    final json = await _api.post(
      '/shops/$shopId/sales',
      body: <String, dynamic>{
        'id': ?id,
        'items': <Map<String, dynamic>>[
          for (final ({String productId, double quantity}) item in items)
            <String, dynamic>{
              'productId': item.productId,
              'quantity': item.quantity,
            },
        ],
        if (counterparty != null && counterparty.trim().isNotEmpty)
          'counterparty': counterparty.trim(),
        if (occurredAt != null) 'occurredAt': occurredAt.millisecondsSinceEpoch,
        'paymentMethod': ?paymentMethod,
        'reference': ?reference,
        'smsId': ?smsId,
        'liveSms': ?liveSms,
      },
    );
    return SaleReceipt.fromJson(json);
  }
}
