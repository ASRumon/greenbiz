import 'dart:math';

/// Generates a UUID v4 without a dependency.
///
/// Offline-created products, transactions and sales need an id before the
/// server sees them. The same id is sent on sync, which is what makes a retry
/// idempotent instead of a duplicate row.
String newUuid() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));

  // RFC 4122: version 4, variant 10xx.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final String hex = bytes
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
