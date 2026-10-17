/// Build-time configuration for the GreenBiz app.
///
/// Nothing here is a secret. The app talks to the Worker, and the Worker holds
/// every API key and every server credential. The client never sees them.
class Env {
  const Env._();

  /// Base URL of the GreenBiz Worker API.
  ///
  /// Defaults to the deployed Worker so an ordinary `flutter run` or a built
  /// APK talks to a reachable server. Override per environment for local
  /// development:
  ///   flutter run --dart-define=GREENBIZ_API_URL=http://10.0.2.2:8787/api
  ///
  /// `10.0.2.2` is the Android emulator's alias for the host machine's
  /// loopback interface, so it reaches a local `wrangler dev`. On a physical
  /// device, pass your computer's LAN IP instead — 10.0.2.2 and 127.0.0.1 are
  /// both unreachable from the phone.
  static const String apiBaseUrl = String.fromEnvironment(
    'GREENBIZ_API_URL',
    defaultValue: 'https://greenbiz.asrumon.workers.dev/api',
  );

  /// Shown in the Profile tab.
  static const String appVersion = '1.0.0';

  /// How far back to read the device inbox. Matches the credit-scoring window
  /// on the server, so we never upload history that cannot affect the score.
  static const int smsLookbackDays = 90;

  /// Maximum messages per bulk upload request. Mirrors the server's cap.
  static const int smsBatchSize = 200;

  /// Sender IDs we upload from.
  ///
  /// Only messages from these senders are read. Everything else — family,
  /// friends, one-time passwords, promotions — is filtered out on the device
  /// and never leaves the phone.
  ///
  /// Bangladesh mobile money uses numeric short codes. India has none: alerts
  /// arrive from bank alphanumeric headers, so the bank suffixes are matched by
  /// `isPaymentSender` instead of an exact comparison.
  static const List<String> paymentSenderIds = <String>[
    // bKash
    '16247',
    'bkash',
    // Nagad (16167 current; 16248 kept for older SIMs)
    '16167',
    '16248',
    'nagad',
    // Rocket / DBBL (16222 current; 16216/16218 kept for older SIMs)
    '16222',
    '16216',
    '16218',
    'rocket',
    'dbbl',
    // Upay (UCB)
    '16268',
    'upay',
    'ucb',
    // India: bank and PSP headers
    'hdfcbk',
    'sbiinb',
    'icicib',
    'axisbk',
    'kotakb',
    'pnb',
    'bob',
    'paytm',
    'phonepe',
    'gpay',
    'ybl',
    'bhim',
  ];

  /// True when [sender] looks like a mobile money or bank alert sender.
  ///
  /// Strips separators first, because India headers arrive as `VM-HDFCBK` and
  /// `AD-SBIINB`, then matches on exact code or suffix.
  static bool isPaymentSender(String sender) {
    final normalized = sender.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (normalized.isEmpty) return false;

    for (final id in paymentSenderIds) {
      if (normalized == id || normalized.endsWith(id)) return true;
    }
    return false;
  }
}
