import '../core/api_client.dart';
import '../core/money.dart';

/// A single movement of money in or out of the shop.
class Transaction {
  const Transaction({
    required this.id,
    required this.shopId,
    this.smsId,
    required this.direction,
    required this.amountMinor,
    required this.currency,
    this.counterparty,
    this.reference,
    required this.occurredAt,
    this.note,
    this.createdAt,
    this.isBusiness = true,
    this.paymentMethod,
    this.smsSender,
    this.smsBody,
    this.syncState = 0,
  });

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    id: json['id']?.toString() ?? '',
    shopId: json['shopId']?.toString() ?? '',
    smsId: asString(json['smsId']),
    direction: json['direction']?.toString() == 'out' ? 'out' : 'in',
    amountMinor: asInt(json['amountMinor']),
    currency: json['currency']?.toString() ?? 'BDT',
    counterparty: asString(json['counterparty']),
    reference: asString(json['reference']),
    occurredAt:
        asDateTime(json['occurredAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0),
    note: asString(json['note']),
    createdAt: asDateTime(json['createdAt']),
    isBusiness: _asBool(json['isBusiness']),
    paymentMethod: asString(json['paymentMethod']),
    smsSender: asString(json['smsSender']),
    smsBody: asString(json['smsBody']),
  );

  /// Accepts a real bool or SQLite's 0/1.
  static bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return true;
  }

  final String id;
  final String shopId;

  /// Set when this row was created from an SMS. Null for manual entries.
  final String? smsId;

  /// 'in' or 'out'.
  final String direction;
  final int amountMinor;
  final String currency;
  final String? counterparty;

  /// Mobile money TrxID, when the source SMS carried one.
  final String? reference;
  final DateTime occurredAt;
  final String? note;
  final DateTime? createdAt;

  /// False when the owner marked this as personal spending/sales. Personal rows
  /// stay visible but are excluded from credit scoring and business totals.
  final bool isBusiness;

  /// Local-only sync state: 0 synced, 1 waiting to sync, 2 sync failed.
  final int syncState;

  /// cash | bkash | nagad | rocket | upay | upi | other. Null on legacy/imported rows.
  final String? paymentMethod;

  /// Sender and raw text of the confirmation this row came from, when the
  /// server has them. Null for manual rows, and for rows cached before the SMS
  /// body was added to the transaction payload.
  final String? smsSender;
  final String? smsBody;

  /// True when the Payments screen can show the original message.
  bool get hasSmsMessage => (smsBody ?? '').trim().isNotEmpty;

  bool get isPending => syncState == 1;
  bool get hasSyncFailed => syncState == 2;

  String get paymentMethodLabel => switch (paymentMethod) {
    'cash' => 'Cash',
    'bkash' => 'bKash',
    'nagad' => 'Nagad',
    'rocket' => 'Rocket',
    'upay' => 'Upay',
    'upi' => 'UPI',
    'other' => 'Other',
    _ => 'Not recorded',
  };

  Transaction copyWith({
    String? direction,
    int? amountMinor,
    String? currency,
    String? counterparty,
    String? reference,
    DateTime? occurredAt,
    String? note,
    bool? isBusiness,
    String? paymentMethod,
    int? syncState,
  }) => Transaction(
    id: id,
    shopId: shopId,
    smsId: smsId,
    direction: direction ?? this.direction,
    amountMinor: amountMinor ?? this.amountMinor,
    currency: currency ?? this.currency,
    counterparty: counterparty ?? this.counterparty,
    reference: reference ?? this.reference,
    occurredAt: occurredAt ?? this.occurredAt,
    note: note ?? this.note,
    createdAt: createdAt,
    isBusiness: isBusiness ?? this.isBusiness,
    paymentMethod: paymentMethod ?? this.paymentMethod,
    smsSender: smsSender,
    smsBody: smsBody,
    syncState: syncState ?? this.syncState,
  );

  bool get isInflow => direction == 'in';

  /// True when this row came from a parsed SMS rather than manual entry.
  bool get isFromSms => smsId != null;

  String get amountLabel => formatMinor(amountMinor, currency: currency);

  String get signedAmountLabel =>
      '${isInflow ? '+' : '-'}${formatMinor(amountMinor, currency: currency)}';

  /// Who the money came from / went to, with a sensible fallback.
  String get counterpartyLabel {
    final value = counterparty?.trim();
    if (value == null || value.isEmpty) {
      return isInflow ? 'Unnamed payer' : 'Unnamed payee';
    }
    return value;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'direction': direction,
    'amountMinor': amountMinor,
    'currency': currency,
    if (counterparty != null) 'counterparty': counterparty,
    if (reference != null) 'reference': reference,
    'occurredAt': occurredAt.millisecondsSinceEpoch,
    if (note != null) 'note': note,
    'isBusiness': isBusiness,
    'paymentMethod': ?paymentMethod,
  };
}

/// One page of transactions plus server-computed totals for the same filter.
///
/// The totals come from the server so the cash-flow card does not have to
/// download every row to add up two numbers.
class TransactionPage {
  const TransactionPage({
    required this.transactions,
    required this.totalInMinor,
    required this.totalOutMinor,
    this.currency = 'BDT',
  });

  factory TransactionPage.fromJson(Map<String, dynamic> json) {
    final transactions = asJsonList(json['transactions'])
        .map(Transaction.fromJson)
        .toList(growable: false);

    final totals = json['totals'];
    final totalsMap = totals is Map
        ? Map<String, dynamic>.from(totals)
        : const <String, dynamic>{};

    return TransactionPage(
      transactions: transactions,
      totalInMinor: asInt(totalsMap['inMinor']),
      totalOutMinor: asInt(totalsMap['outMinor']),
      // Infer from the data: an Indian shop's rows are all INR.
      currency: transactions.isNotEmpty ? transactions.first.currency : 'BDT',
    );
  }

  static const TransactionPage empty = TransactionPage(
    transactions: <Transaction>[],
    totalInMinor: 0,
    totalOutMinor: 0,
  );

  final List<Transaction> transactions;
  final int totalInMinor;
  final int totalOutMinor;
  final String currency;

  int get netMinor => totalInMinor - totalOutMinor;
}
