/// Money formatting that never goes through a floating-point value.
///
/// The server stores every amount as an integer in minor units (poisha / paisa).
/// If the client did `amount / 100` and formatted that, it would reintroduce
/// exactly the rounding error the integer representation exists to prevent.
/// Splitting the integer and the fraction as integers keeps it exact.
library;

/// Formats [minor] (e.g. 150000) as a major-unit string (e.g. "1,500.00").
///
/// [currency] only selects the symbol; the digits are identical.
String formatMinor(
  int minor, {
  String currency = 'BDT',
  bool withSymbol = true,
}) {
  final negative = minor < 0;
  final absolute = negative ? -minor : minor;

  final whole = absolute ~/ 100;
  final fraction = absolute % 100;

  final grouped = _groupThousands(whole.toString());
  final digits = '$grouped.${fraction.toString().padLeft(2, '0')}';

  final body = negative ? '-$digits' : digits;
  if (!withSymbol) return body;
  return '${currencySymbol(currency)} $body';
}

/// Formats minor units without the decimals, for compact card display.
String formatMinorCompact(int minor, {String currency = 'BDT'}) {
  final absolute = minor < 0 ? -minor : minor;
  final whole = absolute ~/ 100;
  final prefix = minor < 0 ? '-' : '';
  return '${currencySymbol(currency)} $prefix${_groupThousands(whole.toString())}';
}

String currencySymbol(String currency) => switch (currency) {
  'INR' => '\u20B9', // ₹
  'BDT' => '\u09F3', // ৳
  _ => currency,
};

/// Converts major units to minor units.
///
/// Only used at the text-input boundary, where the user types "1500.00". The
/// string is parsed digit by digit rather than via `double`, so 1500.05 cannot
/// land as 150004.
int? parseMajorToMinor(String input) {
  final cleaned = input.replaceAll(RegExp(r'[,\s]'), '').trim();
  if (cleaned.isEmpty) return null;

  final match = RegExp(r'^(\d+)(?:[.](\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;

  final whole = int.tryParse(match.group(1)!);
  if (whole == null) return null;

  final fractionText = match.group(2) ?? '';
  final fraction = int.tryParse(fractionText.padRight(2, '0')) ?? 0;

  return whole * 100 + fraction;
}

/// Renders minor units for an editable text field (no symbol, no separators).
String minorToEditable(int minor) {
  final absolute = minor < 0 ? -minor : minor;
  final whole = absolute ~/ 100;
  final fraction = absolute % 100;
  final sign = minor < 0 ? '-' : '';
  if (fraction == 0) return '$sign$whole';
  return '$sign$whole.${fraction.toString().padLeft(2, '0')}';
}

String _groupThousands(String digits) {
  if (digits.length <= 3) return digits;

  final buffer = StringBuffer();
  final firstGroupLength = digits.length % 3 == 0 ? 3 : digits.length % 3;

  buffer.write(digits.substring(0, firstGroupLength));
  for (var i = firstGroupLength; i < digits.length; i += 3) {
    buffer.write(',');
    buffer.write(digits.substring(i, i + 3));
  }
  return buffer.toString();
}

/// "3 days ago" / "just now", for the SMS sync status line.
String relativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return 'never';

  final reference = now ?? DateTime.now();
  final difference = reference.difference(when);
  if (difference.isNegative) return 'just now';
  if (difference.inSeconds < 45) return 'just now';
  if (difference.inMinutes < 2) return '1 minute ago';
  if (difference.inMinutes < 60) return '${difference.inMinutes} minutes ago';
  if (difference.inHours < 2) return '1 hour ago';
  if (difference.inHours < 24) return '${difference.inHours} hours ago';
  if (difference.inDays < 2) return 'yesterday';
  if (difference.inDays < 30) return '${difference.inDays} days ago';
  final months = difference.inDays ~/ 30;
  return months < 2 ? '1 month ago' : '$months months ago';
}
