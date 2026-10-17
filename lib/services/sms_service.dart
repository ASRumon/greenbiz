import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/env.dart';
import '../core/sms_structural.dart';
import '../models/live_sms_payment.dart';

/// The subset of `permission_handler` statuses this app cares about.
enum SmsPermissionState {
  granted,

  /// Denied, but the OS will show the dialog again next time.
  denied,

  /// Denied for good — only the system settings app can change it now.
  permanentlyDenied,

  /// Blocked by device policy (MDM / parental controls).
  restricted;

  bool get canAskAgain => this == SmsPermissionState.denied;
  bool get isGranted => this == SmsPermissionState.granted;
}

/// One message pulled from the device inbox, ready to upload.
class SmsInboxMessage {
  const SmsInboxMessage({
    required this.sender,
    required this.body,
    required this.receivedAt,
  });

  final String sender;
  final String body;
  final DateTime receivedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sender': sender,
    'body': body,
    'receivedAt': receivedAt.millisecondsSinceEpoch,
  };
}

/// Outcome of scanning the device inbox, before anything is uploaded.
///
/// The counts are reported separately so the UI can be honest about what
/// happened: "read 412 messages, 9 were payment confirmations, 0 left the
/// phone". Collapsing that into one number would hide the fact that only
/// payment confirmations are ever uploaded.
class SmsInboxScan {
  const SmsInboxScan({
    required this.scannedCount,
    required this.paymentMessages,
    required this.skippedNotPayment,
    required this.skippedTooOld,
  });

  static const SmsInboxScan empty = SmsInboxScan(
    scannedCount: 0,
    paymentMessages: <SmsInboxMessage>[],
    skippedNotPayment: 0,
    skippedTooOld: 0,
  );

  /// How many inbox messages were read from the device.
  final int scannedCount;

  /// The only messages that are uploaded.
  final List<SmsInboxMessage> paymentMessages;

  /// Read but not from a mobile money / bank sender.
  final int skippedNotPayment;

  /// Payment messages older than the credit-scoring window.
  final int skippedTooOld;

  int get uploadedCandidateCount => paymentMessages.length;
}

/// Server-side outcome of one full sync, aggregated across batches.
class SmsSyncSummary {
  const SmsSyncSummary({
    required this.scannedCount,
    required this.paymentMessagesFound,
    required this.uploaded,
    required this.inserted,
    required this.duplicates,
    required this.notPayment,
    required this.parsed,
    required this.pending,
    required this.failed,
    required this.regexHits,
    required this.aiHits,
    required this.transactionsCreated,
    this.score,
  });

  static const SmsSyncSummary empty = SmsSyncSummary(
    scannedCount: 0,
    paymentMessagesFound: 0,
    uploaded: 0,
    inserted: 0,
    duplicates: 0,
    notPayment: 0,
    parsed: 0,
    pending: 0,
    failed: 0,
    regexHits: 0,
    aiHits: 0,
    transactionsCreated: 0,
  );

  final int scannedCount;
  final int paymentMessagesFound;
  final int uploaded;
  final int inserted;
  final int duplicates;
  final int notPayment;
  final int parsed;
  final int pending;
  final int failed;
  final int regexHits;
  final int aiHits;
  final int transactionsCreated;

  /// Credit score after the server recomputed it, when available.
  final int? score;

  bool get nothingNew => inserted == 0 && transactionsCreated == 0;

  /// The one-line result shown after a sync.
  String get headline {
    if (uploaded == 0) return 'No new payment messages found.';
    if (transactionsCreated > 0) {
      return 'Added $transactionsCreated new transaction${transactionsCreated == 1 ? '' : 's'}.';
    }
    if (duplicates > 0) return 'Everything was already synced.';
    return 'Sync finished.';
  }

  /// The detail line, which is where the privacy story is told.
  String get detail {
    final parts = <String>[
      'Read $scannedCount messages on this phone',
      '$paymentMessagesFound were payment confirmations',
      if (inserted > 0) '$inserted new',
      if (duplicates > 0) '$duplicates already synced',
      if (pending > 0) '$pending awaiting review',
      if (failed > 0) '$failed not payments',
    ];
    return parts.join(' · ');
  }

  /// How the messages were actually parsed. Proves the regex tier is doing the
  /// work rather than the app paying for an LLM call on every message.
  String get parserBreakdown {
    if (parsed == 0) return 'No messages needed parsing.';
    return '$regexHits matched by pattern, $aiHits by AI fallback';
  }
}

/// What the server did with one uploaded confirmation.
class SmsIngestResult {
  const SmsIngestResult({
    required this.smsId,
    required this.outcome,
    required this.provider,
    required this.transactionId,
  });

  final String smsId;

  /// inserted | duplicate | not_payment.
  final String outcome;
  final String provider;

  /// Set when the message created a ledger row, or null on a duplicate.
  final String? transactionId;

  bool get isNew => outcome == 'inserted';
}

class SmsService {
  SmsService(this._api);

  final ApiClient _api;

  /* ---------------------------------------------------------------------- */
  /* Permissions                                                             */
  /* ---------------------------------------------------------------------- */

  Future<SmsPermissionState> checkPermission() async =>
      _map(await Permission.sms.status);

  /// Shows the OS permission dialog.
  ///
  /// READ_SMS is a dangerous permission, so this is the only place it is
  /// requested and it is always triggered by an explicit user tap on the
  /// Profile tab — never automatically at launch.
  Future<SmsPermissionState> requestPermission() async =>
      _map(await Permission.sms.request());

  /// Android 13+ requires a separate permission for the background alert.
  Future<bool> checkNotificationPermission() async =>
      (await Permission.notification.status).isGranted;

  Future<bool> requestNotificationPermission() async =>
      (await Permission.notification.request()).isGranted;

  /// Opens the system settings page, for a permanently denied permission.
  Future<bool> openSettings() => openAppSettings();

  SmsPermissionState _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return SmsPermissionState.granted;
    if (status.isPermanentlyDenied) return SmsPermissionState.permanentlyDenied;
    if (status.isRestricted) return SmsPermissionState.restricted;
    return SmsPermissionState.denied;
  }

  /* ---------------------------------------------------------------------- */
  /* Reading the inbox                                                       */
  /* ---------------------------------------------------------------------- */

  /// Reads the device inbox and keeps only recent mobile money / bank messages.
  ///
  /// Everything else is discarded **on the device**: personal messages, OTPs,
  /// and promotions are never sent to the server, so they cannot be stored,
  /// logged, or leaked. This filter is the core privacy control of the app.
  Future<SmsInboxScan> scanInbox({
    int lookbackDays = Env.smsLookbackDays,
    int maxScan = 1000,
  }) async {
    final List<SmsMessage> raw;
    try {
      // The plugin caps a single query at 1000 messages; asking for the window
      // and filtering by date client-side is more predictable than paging.
      raw = await SmsQuery().querySms(
        count: maxScan,
        kinds: const <SmsQueryKind>[SmsQueryKind.inbox],
      );
    } on PlatformException catch (error) {
      throw ApiException(
        code: 'SMS_READ_FAILED',
        message: error.message?.isNotEmpty == true
            ? 'Could not read the message inbox: ${error.message}'
            : 'Could not read the message inbox. Check the SMS permission.',
      );
    }

    final cutoff = DateTime.now().subtract(Duration(days: lookbackDays));

    final paymentMessages = <SmsInboxMessage>[];
    var skippedNotPayment = 0;
    var skippedTooOld = 0;

    for (final message in raw) {
      final sender = message.address ?? '';
      final body = message.body ?? '';
      final receivedAt = message.date;

      if (sender.isEmpty || body.isEmpty || receivedAt == null) continue;

      if (!looksLikePaymentSms(sender, body)) {
        skippedNotPayment++;
        continue;
      }
      if (receivedAt.isBefore(cutoff)) {
        skippedTooOld++;
        continue;
      }

      paymentMessages.add(
        SmsInboxMessage(sender: sender, body: body, receivedAt: receivedAt),
      );
    }

    // Newest first, so a partially successful upload still syncs the most
    // relevant messages.
    paymentMessages.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));

    return SmsInboxScan(
      scannedCount: raw.length,
      paymentMessages: paymentMessages,
      skippedNotPayment: skippedNotPayment,
      skippedTooOld: skippedTooOld,
    );
  }

  /* ---------------------------------------------------------------------- */
  /* Syncing                                                                 */
  /* ---------------------------------------------------------------------- */

  /// Uploads one live-captured confirmation.
  ///
  /// This is deliberately a single-message call: a message that arrived a
  /// second ago should reach the ledger without rescanning 90 days of inbox.
  /// The server dedupes on the same four-column key as a bulk sync, so a live
  /// capture and the next full scan cannot double-book it.
  Future<SmsIngestResult> ingestOne({
    required String shopId,
    required LiveSmsPayment payment,
  }) async {
    final json = await _api.post(
      '/shops/$shopId/sms/bulk',
      body: <String, dynamic>{
        'messages': <Map<String, dynamic>>[payment.toInboxJson()],
      },
    );

    final List<dynamic> results = asJsonList(json['results']);
    final Map<String, dynamic> first = results.isNotEmpty
        ? Map<String, dynamic>.from(results.first as Map)
        : const <String, dynamic>{};

    return SmsIngestResult(
      smsId: first['smsId']?.toString() ?? '',
      outcome: first['outcome']?.toString() ?? 'not_payment',
      provider: first['provider']?.toString() ?? 'unknown',
      transactionId: first['transactionId']?.toString(),
    );
  }

  /// Scans the inbox and uploads the payment confirmations for [shopId].
  ///
  /// Idempotent end to end: the server dedupes on
  /// `(shop_id, sender, body, received_at)`, so running this repeatedly — or
  /// after a crash mid-upload — cannot double-count anything.
  Future<SmsSyncSummary> syncShop({
    required String shopId,
    int lookbackDays = Env.smsLookbackDays,
    void Function(int done, int total)? onProgress,
  }) async {
    final scan = await scanInbox(lookbackDays: lookbackDays);
    final messages = scan.paymentMessages;

    if (messages.isEmpty) {
      return SmsSyncSummary.empty.scannedCopy(scan);
    }

    var inserted = 0;
    var duplicates = 0;
    var notPayment = 0;
    var parsed = 0;
    var pending = 0;
    var failed = 0;
    var regexHits = 0;
    var aiHits = 0;
    var transactionsCreated = 0;
    int? score;
    var uploaded = 0;

    for (var start = 0; start < messages.length; start += Env.smsBatchSize) {
      final end = math.min(start + Env.smsBatchSize, messages.length);
      final batch = messages.sublist(start, end);

      final json = await _api.post(
        '/shops/$shopId/sms/bulk',
        body: <String, dynamic>{
          'messages': batch
              .map((message) => message.toJson())
              .toList(growable: false),
        },
      );

      final summary = json['summary'] is Map
          ? Map<String, dynamic>.from(json['summary'] as Map)
          : const <String, dynamic>{};

      uploaded += batch.length;
      inserted += asInt(summary['inserted']);
      duplicates += asInt(summary['duplicates']);
      notPayment += asInt(summary['notPayment']);
      parsed += asInt(summary['parsed']);
      pending += asInt(summary['pending']);
      failed += asInt(summary['failed']);
      transactionsCreated += asInt(summary['transactionsCreated']);

      final bySource = summary['bySource'] is Map
          ? Map<String, dynamic>.from(summary['bySource'] as Map)
          : const <String, dynamic>{};
      regexHits += asInt(bySource['regex']);
      aiHits += asInt(bySource['llm']);

      if (summary['score'] != null) score = asInt(summary['score']);

      onProgress?.call(end, messages.length);
    }

    return SmsSyncSummary(
      scannedCount: scan.scannedCount,
      paymentMessagesFound: scan.paymentMessages.length,
      uploaded: uploaded,
      inserted: inserted,
      duplicates: duplicates,
      notPayment: notPayment,
      parsed: parsed,
      pending: pending,
      failed: failed,
      regexHits: regexHits,
      aiHits: aiHits,
      transactionsCreated: transactionsCreated,
      score: score,
    );
  }
}

extension on SmsSyncSummary {
  /// A zero-result summary that still reports what the device scan saw.
  SmsSyncSummary scannedCopy(SmsInboxScan scan) => SmsSyncSummary(
    scannedCount: scan.scannedCount,
    paymentMessagesFound: 0,
    uploaded: 0,
    inserted: 0,
    duplicates: 0,
    notPayment: 0,
    parsed: 0,
    pending: 0,
    failed: 0,
    regexHits: 0,
    aiHits: 0,
    transactionsCreated: 0,
  );
}
