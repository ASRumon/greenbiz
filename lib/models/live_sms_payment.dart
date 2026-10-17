import '../core/sms_payment_parser.dart';

/// One payment confirmation the phone captured while it was running.
///
/// The Android receiver writes a compact JSON record to the app's preferences
/// before it hands the message to Flutter, so a message that arrives while the
/// engine is starting (or while the app is in the background) is never lost.
class LiveSmsPayment {
  const LiveSmsPayment({
    required this.id,
    required this.sender,
    required this.body,
    required this.receivedAt,
    required this.amountMinor,
    required this.method,
    required this.reference,
    required this.isInflow,
  });

  factory LiveSmsPayment.fromNative(Map<dynamic, dynamic> map) {
    final String sender = map['sender']?.toString() ?? '';
    final String body = map['body']?.toString() ?? '';
    final int millis =
        (map['receivedAt'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;

    final DateTime receivedAt = DateTime.fromMillisecondsSinceEpoch(millis);
    final ParsedPaymentSms parsed = parsePaymentSms(
      sender: sender,
      body: body,
      receivedAt: receivedAt,
    );

    return LiveSmsPayment(
      id:
          map['id']?.toString() ??
          '${millis}_${sender.hashCode}_${body.hashCode}',
      sender: sender,
      body: body,
      receivedAt: receivedAt,
      amountMinor:
          parsed.amountMinor ?? (map['amountMinor'] as num?)?.toInt() ?? 0,
      method: parsed.method ?? map['method']?.toString() ?? 'other',
      reference: parsed.reference ?? map['reference']?.toString(),
      isInflow: parsed.isInflow,
    );
  }

  final String id;
  final String sender;
  final String body;
  final DateTime receivedAt;
  final int amountMinor;

  /// cash | bkash | nagad | rocket | upay | upi | other.
  final String method;
  final String? reference;
  final bool isInflow;

  String get methodLabel => switch (method) {
    'cash' => 'Cash',
    'bkash' => 'bKash',
    'nagad' => 'Nagad',
    'rocket' => 'Rocket',
    'upay' => 'Upay',
    'upi' => 'UPI',
    _ => 'Other',
  };

  /// The one-line title used by the prompt and the notification.
  String get headline => 'Payment received · $methodLabel';

  /// The payload the server accepts as `liveSms` on a sale. The body is what
  /// makes the server able to re-derive the amount, provider and TrxID.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'sender': sender,
    'body': body,
    'receivedAt': receivedAt.millisecondsSinceEpoch,
  };

  /// The shape `SmsService` uploads in a bulk batch.
  Map<String, dynamic> toInboxJson() => toJson();
}
