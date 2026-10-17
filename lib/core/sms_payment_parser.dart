import 'sms_structural.dart';

/// What a payment confirmation message appears to say.
///
/// This parser is intentionally small and conservative. The server's parser is
/// still the authority that decides what gets booked; this one exists so the
/// phone can react the moment a message arrives, without waiting for a network
/// round trip.
class ParsedPaymentSms {
  const ParsedPaymentSms({
    required this.isPaymentCandidate,
    required this.isInflow,
    required this.amountMinor,
    required this.method,
    required this.reference,
  });

  /// The sender is a known mobile-money / bank alert sender.
  final bool isPaymentCandidate;

  /// The message says money came in (not an outgoing payment).
  final bool isInflow;

  /// Amount in minor units, or null when no trustworthy amount was found.
  final int? amountMinor;

  /// cash | bkash | nagad | rocket | upay | upi | other.
  final String? method;

  /// Mobile-money TrxID, when the message carries one.
  final String? reference;

  /// True only when this is a received-money message with a usable amount.
  bool get isReceivedMoney =>
      isPaymentCandidate && isInflow && (amountMinor ?? 0) > 0;
}

/// Reads a single inbound message without touching the network.
///
/// The heavy lifting lives in [parseSmsStructurally], which is shared with the
/// inbox filter. This wrapper exposes the small result the live-capture UI
/// needs and keeps the old call sites unchanged.
ParsedPaymentSms parsePaymentSms({
  required String sender,
  required String body,
  required DateTime receivedAt,
}) {
  if (!looksLikePaymentSms(sender, body)) {
    return const ParsedPaymentSms(
      isPaymentCandidate: false,
      isInflow: false,
      amountMinor: null,
      method: null,
      reference: null,
    );
  }

  final StructuralSmsResult? result = parseSmsStructurally(
    sender: sender,
    body: body,
  );
  final String provider = detectPaymentProvider(sender, body);

  return ParsedPaymentSms(
    isPaymentCandidate: true,
    isInflow: result?.isInflow ?? false,
    amountMinor: result?.amountMinor,
    method: provider == 'other' ? null : provider,
    reference: result?.reference,
  );
}
