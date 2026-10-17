import 'dart:math' as math;

import 'env.dart';
import 'money.dart';

/// Structural payment-SMS parsing shared by live capture and inbox sync.
///
/// Mobile-money providers change words, add templates, and issue new
/// shortcodes. This parser does not depend on one sentence: it finds the money
/// amount by what surrounds it, decides direction from the transaction verbs,
/// and reads the provider from either the sender or the body.
///
/// The server runs the same algorithm and remains the authority. This copy
/// exists so the phone can filter the inbox and show a prompt instantly.
class StructuralSmsResult {
  const StructuralSmsResult({
    required this.provider,
    required this.isInflow,
    required this.amountMinor,
    required this.reference,
    required this.counterparty,
    required this.confidence,
  });

  /// bkash | nagad | rocket | upay | upi | other.
  final String provider;
  final bool isInflow;
  final int amountMinor;
  final String? reference;
  final String? counterparty;
  final double confidence;
}

final RegExp _otpWords = RegExp(
  r'\b(?:otp|one[\s-]*time\s*(?:password|pin)|verification\s*code|do\s+not\s+share|security\s*code)\b',
  caseSensitive: false,
);

final RegExp _promoWords = RegExp(
  r'\b(?:cashback|promo|promotion|offer|discount|coupon|winner|prize|lottery|apply\s+now|loan\s+offer)\b',
  caseSensitive: false,
);

final RegExp _transactionSignal = RegExp(
  r'\b(?:received?|receiving|credited|deposited?|added|sent|send|paid|payment|pay|collection|cash[\s-]*(?:in|out)|recharge|bill\s*pay|transfer(?:red)?|debited?|withdrawn?|withdraw|merchant|trx\s*id|trxid|txn\s*id|transaction\s*id)\b',
  caseSensitive: false,
);

final RegExp _trxId = RegExp(
  r'\b(?:trx|txn|transaction)\s*id\b\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])',
  caseSensitive: false,
);

final RegExp _fallbackRef = RegExp(
  r'\b(?:reference|ref)\s*(?:no|id)?\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])',
  caseSensitive: false,
);

final RegExp _amountRegex = RegExp(
  r'(?:tk\.?|bdt|taka|৳|rs\.?|inr|₹)\s*\.?\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?(?![0-9]|\.[0-9])',
  caseSensitive: false,
);

final RegExp _excludedAmountLabel = RegExp(
  r'(?:balance|available|current|total|opening|previous|wallet|merchant\s+balance|fee|charge|limit|due)\s*(?:is\s*)?[:=]?\s*$',
  caseSensitive: false,
);

/// True when a message is worth uploading or alerting on.
///
/// A known sender is always accepted: the server may understand a template the
/// phone does not. An unknown sender needs a provider brand plus either a
/// TrxID or a received-money phrase, which keeps personal messages out.
bool looksLikePaymentSms(String sender, String body) {
  final String text = normalizeSmsDigits(body);
  if (_otpWords.hasMatch(text)) return false;
  if (_promoWords.hasMatch(text) && !_trxId.hasMatch(text)) return false;

  if (Env.isPaymentSender(sender)) return true;
  if (detectPaymentProvider(sender, text) == 'other') return false;
  if (!_transactionSignal.hasMatch(text)) return false;
  if (_trxId.hasMatch(text)) return true;

  final bool receivedSignal = RegExp(
    r'\b(?:received?|credited|deposited?|collection|cash[\s-]*in|add(?:ed)?\s*money|merchant\s+(?:pay|payment)\s+received)\b',
    caseSensitive: false,
  ).hasMatch(text);

  return receivedSignal && _amountRegex.hasMatch(text);
}

/// Provider from the sender, then from a brand word in the body.
String detectPaymentProvider(String sender, String body) {
  final String normalized = sender.toLowerCase().replaceAll(
    RegExp('[^a-z0-9]'),
    '',
  );
  final String text = body.toLowerCase();

  if (normalized == '16247' ||
      normalized.startsWith('bkash') ||
      text.contains('bkash')) {
    return 'bkash';
  }
  if (normalized == '16167' ||
      normalized == '16248' ||
      normalized.startsWith('nagad') ||
      text.contains('nagad')) {
    return 'nagad';
  }
  if (normalized == '16222' ||
      normalized == '16216' ||
      normalized == '16218' ||
      normalized.startsWith('rocket') ||
      normalized.startsWith('dbbl') ||
      text.contains('rocket') ||
      text.contains('dbbl')) {
    return 'rocket';
  }
  if (normalized == '16268' ||
      normalized.startsWith('upay') ||
      normalized.startsWith('ucb') ||
      RegExp(r'\b(?:upay|ucb)\b').hasMatch(text)) {
    return 'upay';
  }
  if (RegExp(
        r'(?:hdfcbk|sbiinb|icicib|axisbk|kotakb|pnb|bob|paytm|phonepe|gpay|ybl|bhim)$',
      ).hasMatch(normalized) ||
      RegExp(r'\b(?:upi|paytm|phonepe|gpay|bhim|inr|rs\.?\s*\d)\b')
          .hasMatch(text)) {
    return 'upi';
  }
  return 'other';
}

/// Parses one message; returns null when it is not a usable payment.
StructuralSmsResult? parseSmsStructurally({
  required String sender,
  required String body,
}) {
  final String text = normalizeSmsDigits(body).replaceAll('\u00a0', ' ');
  if (_otpWords.hasMatch(text)) return null;
  if (_promoWords.hasMatch(text) && !_trxId.hasMatch(text)) return null;
  if (!_transactionSignal.hasMatch(text)) return null;

  final String provider = detectPaymentProvider(sender, text);
  if (provider == 'other' && !_trxId.hasMatch(text)) return null;

  final _AmountCandidate? amount = _extractAmount(text);
  if (amount == null) return null;

  final bool isInflow = _decideDirection(text, amount);
  final String? reference = _extractReference(text);

  return StructuralSmsResult(
    provider: provider,
    isInflow: isInflow,
    amountMinor: amount.minor,
    reference: reference,
    counterparty: _extractCounterparty(text, amount, isInflow),
    confidence: _directionScore(text) >= 3 ? 0.92 : 0.8,
  );
}

/// Bengali and Devanagari digits to ASCII, so one amount regex works for all.
String normalizeSmsDigits(String input) {
  final StringBuffer buffer = StringBuffer();
  for (final int codePoint in input.runes) {
    if (codePoint >= 0x09e6 && codePoint <= 0x09ef) {
      buffer.write(codePoint - 0x09e6);
    } else if (codePoint >= 0x0966 && codePoint <= 0x096f) {
      buffer.write(codePoint - 0x0966);
    } else {
      buffer.writeCharCode(codePoint);
    }
  }
  return buffer.toString();
}

class _AmountCandidate {
  const _AmountCandidate({
    required this.index,
    required this.end,
    required this.minor,
    required this.score,
  });

  final int index;
  final int end;
  final int minor;
  final int score;
}

_AmountCandidate? _extractAmount(String text) {
  final Map<int, _AmountCandidate> candidates = <int, _AmountCandidate>{};

  void collect(RegExp regex, {required bool hasCurrency}) {
    for (final RegExpMatch match in regex.allMatches(text)) {
      final String? raw = match.group(1);
      if (raw == null) continue;

      final int index = match.start + match.group(0)!.indexOf(raw);
      final int? minor = parseMajorToMinor(raw);
      if (minor == null || minor <= 0) continue;

      final String before = text
          .substring(math.max(0, index - 44), index)
          .toLowerCase();
      if (_excludedAmountLabel.hasMatch(
        before.replaceFirst(RegExp(r'[:\s]+$'), ' '),
      )) {
        continue;
      }

      final String after = text
          .substring(
            index + raw.length,
            math.min(text.length, index + raw.length + 56),
          )
          .toLowerCase();

      var score = 0;
      if (RegExp(
        r'(?:amount|received?|credited|deposited|added\s*to|collection|cash\s*in|add\s*money)',
      ).hasMatch(before)) {
        score += 4;
      }
      if (RegExp(
        r'(?:payment|paid|sent|send|cash\s*out|recharge|bill\s*pay|transfer|merchant)',
      ).hasMatch(before)) {
        score += 2;
      }
      if (RegExp(r'^\s*(?:to|from)\b').hasMatch(after)) score += 2;
      if (RegExp(r'(?:added\s+to|credited|deposited|received)')
          .hasMatch(after)) {
        score += 4;
      }

      if (!hasCurrency && score == 0) continue;

      final _AmountCandidate? existing = candidates[index];
      if (existing != null && existing.score >= score) continue;
      candidates[index] = _AmountCandidate(
        index: index,
        end: index + raw.length,
        minor: minor,
        score: score,
      );
    }
  }

  collect(
    RegExp(
      r'(?:tk\.?|bdt|taka|৳|rs\.?|inr|₹)\s*\.?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])',
      caseSensitive: false,
    ),
    hasCurrency: true,
  );
  collect(
    RegExp(
      r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])\s*(?:tk\.?|bdt|taka|rs\.?|inr|৳|₹)',
      caseSensitive: false,
    ),
    hasCurrency: true,
  );
  collect(
    RegExp(
      r'(?:amount|paid|received|sent|collection|cash\s*(?:in|out)|recharge|bill\s*pay|transfer|payment)\s*(?:of|is|:)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])',
      caseSensitive: false,
    ),
    hasCurrency: false,
  );

  if (candidates.isEmpty) return null;
  final List<_AmountCandidate> ranked = candidates.values.toList()
    ..sort((_AmountCandidate a, _AmountCandidate b) {
      final int byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
  return ranked.first;
}

bool _decideDirection(String text, _AmountCandidate amount) {
  final String lower = text.toLowerCase();
  var inflow = 0;
  var outflow = 0;

  final List<(RegExp, int)> inflowRules = <(RegExp, int)>[
    (RegExp(r'\bmerchant\s+(?:pay|payment)\s+received\b'), 8),
    (RegExp(r'\bpayment\s+received\b'), 7),
    (RegExp(r'\breceived\s+payment\b'), 7),
    (RegExp(r'\bcollection\s+of\b'), 7),
    (RegExp(r'\bcash[\s-]*in\b'), 7),
    (RegExp(r'\badd(?:ed)?\s+money\b'), 7),
    (RegExp(r'\badded\s+to\s+(?:your\s+)?(?:account|wallet)\b'), 7),
    (RegExp(r'\b(?:money\s+)?received\b'), 6),
    (RegExp(r'\b(?:you\s+have\s+)?received?\b'), 6),
    (RegExp(r'\breceived\s+from\b'), 6),
    (RegExp(r'\bcredited\b'), 6),
    (RegExp(r'\bdeposited?\b'), 6),
  ];
  final List<(RegExp, int)> outflowRules = <(RegExp, int)>[
    (RegExp(r'\bsent\s+money\b'), 8),
    (RegExp(r'\bmerchant\s+(?:pay|payment)\s+of\b'), 8),
    (RegExp(r'\b(?:you\s+have\s+)?sent\b'), 7),
    (RegExp(r'\bcash[\s-]*out\b'), 7),
    (RegExp(r'\b(?:mobile\s+)?recharge\b'), 7),
    (RegExp(r'\bbill\s*pay(?:ment)?\b'), 7),
    (RegExp(r'\btransfer(?:red)?\b'), 7),
    (RegExp(r'\b(?:you\s+have\s+)?paid\b'), 7),
    (RegExp(r'\bpayment\s+(?:of|tk|bdt|taka|৳|rs|inr)\b'), 6),
    (RegExp(r'\bdebited\b'), 6),
    (RegExp(r'\bwithdrawn?\b'), 6),
    (RegExp(r'\bpurchase\b'), 5),
  ];

  for (final (RegExp regex, int weight) in inflowRules) {
    if (regex.hasMatch(lower)) inflow += weight;
  }
  for (final (RegExp regex, int weight) in outflowRules) {
    if (regex.hasMatch(lower)) outflow += weight;
  }

  final String after = lower.substring(
    amount.end,
    math.min(lower.length, amount.end + 90),
  );
  final int fromAt = RegExp(r'\bfrom\b').firstMatch(after)?.start ?? -1;
  final int toAt = RegExp(r'\bto\b').firstMatch(after)?.start ?? -1;
  if (fromAt >= 0 && (toAt < 0 || fromAt < toAt)) inflow += 3;
  if (toAt >= 0 && (fromAt < 0 || toAt < fromAt)) outflow += 3;

  if (inflow == outflow) return true;
  return inflow > outflow;
}

int _directionScore(String text) {
  final String lower = text.toLowerCase();
  var score = 0;
  for (final String pattern in <String>[
    r'\bmerchant\s+(?:pay|payment)\s+received\b',
    r'\bpayment\s+received\b',
    r'\breceived\s+payment\b',
    r'\bcollection\s+of\b',
    r'\bcash[\s-]*in\b',
    r'\badd(?:ed)?\s+money\b',
    r'\badded\s+to\s+(?:your\s+)?(?:account|wallet)\b',
    r'\b(?:money\s+)?received\b',
    r'\b(?:you\s+have\s+)?received?\b',
    r'\breceived\s+from\b',
    r'\bcredited\b',
    r'\bdeposited?\b',
  ]) {
    if (RegExp(pattern).hasMatch(lower)) score += 6;
  }
  for (final String pattern in <String>[
    r'\bsent\s+money\b',
    r'\bmerchant\s+(?:pay|payment)\s+of\b',
    r'\b(?:you\s+have\s+)?sent\b',
    r'\bcash[\s-]*out\b',
    r'\b(?:mobile\s+)?recharge\b',
    r'\bbill\s*pay(?:ment)?\b',
    r'\btransfer(?:red)?\b',
    r'\b(?:you\s+have\s+)?paid\b',
    r'\bpayment\s+(?:of|tk|bdt|taka|৳|rs|inr)\b',
    r'\bdebited\b',
    r'\bwithdrawn?\b',
  ]) {
    if (RegExp(pattern).hasMatch(lower)) score += 6;
  }
  return score;
}

String? _extractReference(String text) {
  final String? primary = _trxId.firstMatch(text)?.group(1);
  if (primary != null) return primary.toUpperCase();

  final String? fallback = _fallbackRef.firstMatch(text)?.group(1);
  return fallback?.toUpperCase();
}

String? _extractCounterparty(
  String text,
  _AmountCandidate amount,
  bool isInflow,
) {
  final String after = text.substring(
    amount.end,
    math.min(text.length, amount.end + 180),
  );
  final List<String> candidates = <String>[];

  if (isInflow) {
    final RegExpMatch? from = RegExp(
      r'\bfrom\s+(?:(?:agent|customer|merchant|account)\s+)?([A-Za-z0-9][^.\n]{1,70})',
      caseSensitive: false,
    ).firstMatch(after);
    if (from?.group(1) != null) candidates.add(from!.group(1)!);
  } else {
    final RegExpMatch? to = RegExp(
      r'\bto\s+([A-Za-z0-9][^.\n]{1,70})',
      caseSensitive: false,
    ).firstMatch(after);
    if (to?.group(1) != null) candidates.add(to!.group(1)!);

    final RegExpMatch? organization = RegExp(
      r'\b(?:organization|biller|merchant)\s*[:#-]?\s*([A-Za-z0-9][^.\n]{1,70})',
      caseSensitive: false,
    ).firstMatch(text);
    if (organization?.group(1) != null) {
      candidates.add(organization!.group(1)!);
    }
  }

  final RegExpMatch? agent = RegExp(
    r'\b(?:agent|through\s+agent)\s*[:#-]?\s*([0-9Xx*][0-9Xx*\s-]{5,30})',
    caseSensitive: false,
  ).firstMatch(text);
  if (agent?.group(1) != null) candidates.add(agent!.group(1)!);

  for (final String candidate in candidates) {
    final String? cleaned = _cleanCounterparty(candidate);
    if (cleaned != null) return cleaned;
  }
  return null;
}

String? _cleanCounterparty(String raw) {
  final RegExp stop = RegExp(
    r'(?:successful|success|failed|failure|completed|trx|txn|transaction\s*id|fee|balance|date|store\s*id|counter|reference|ref\b|is\s+successful|is\s+completed|at\s+\d|through|via)',
    caseSensitive: false,
  );
  final RegExpMatch? match = stop.firstMatch(raw);
  String value = match == null ? raw : raw.substring(0, match.start);
  value = value
      .replaceFirst(RegExp(r'^[\s:,-]+'), '')
      .replaceFirst(RegExp(r'[\s:;,.!-]+$'), '')
      .trim();

  if (value.length < 2) return null;
  if (RegExp(
    r'^(?:your\s+)?(?:account|a/c|wallet|card)$',
    caseSensitive: false,
  ).hasMatch(value)) {
    return null;
  }
  return value.length <= 120 ? value : value.substring(0, 120);
}
