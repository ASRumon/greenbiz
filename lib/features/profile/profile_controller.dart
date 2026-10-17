import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../models/live_sms_payment.dart';
import '../../services/sms_service.dart';
import '../auth/auth_controller.dart';
import '../finance/finance_controller.dart';
import '../inventory/inventory_controller.dart';

/// Everything the Profile tab needs to know about SMS reading.
class SmsSyncState {
  const SmsSyncState({
    required this.permission,
    this.notificationsEnabled = false,
    this.isCheckingPermission = false,
    this.isSyncing = false,
    this.lastSyncedAt,
    this.lastSummary,
    this.lastScan,
    this.errorMessage,
  });

  final SmsPermissionState permission;

  /// Whether Android will show the "new payment" alert while the app is away.
  final bool notificationsEnabled;
  final bool isCheckingPermission;
  final bool isSyncing;

  /// When a sync last completed successfully.
  final DateTime? lastSyncedAt;

  /// Result of the most recent sync, for the summary card.
  final SmsSyncSummary? lastSummary;

  /// What the last device scan saw, including what it deliberately skipped.
  final SmsInboxScan? lastScan;

  final String? errorMessage;

  bool get canSync => permission.isGranted && !isSyncing;
  bool get needsPermission => !permission.isGranted;

  SmsSyncState copyWith({
    SmsPermissionState? permission,
    bool? notificationsEnabled,
    bool? isCheckingPermission,
    bool? isSyncing,
    DateTime? lastSyncedAt,
    SmsSyncSummary? lastSummary,
    SmsInboxScan? lastScan,
    String? errorMessage,
    bool clearError = false,
  }) => SmsSyncState(
    permission: permission ?? this.permission,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    isCheckingPermission: isCheckingPermission ?? this.isCheckingPermission,
    isSyncing: isSyncing ?? this.isSyncing,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    lastSummary: lastSummary ?? this.lastSummary,
    lastScan: lastScan ?? this.lastScan,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Owns the SMS permission and sync lifecycle.
///
/// Shared between the Profile tab (where sync is triggered) and the Finance tab
/// (where the last-sync status is shown), so both read the same state instead of
/// each keeping its own copy that can drift.
class SmsSyncController extends Notifier<SmsSyncState> {
  static const String _lastSyncKey = 'greenbiz.last_sms_sync';

  @override
  SmsSyncState build() {
    final int? millis = ref
        .read(sharedPreferencesProvider)
        .getInt(_lastSyncKey);

    // Permission lives in the OS, so it has to be read asynchronously. The
    // initial value is deliberately pessimistic: assuming "denied" until told
    // otherwise means the UI never offers a sync that will immediately fail.
    Future<void>.microtask(refreshPermission);

    return SmsSyncState(
      permission: SmsPermissionState.denied,
      isCheckingPermission: true,
      lastSyncedAt: millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }

  Future<void> refreshPermission() async {
    state = state.copyWith(isCheckingPermission: true, clearError: true);
    try {
      final SmsService service = ref.read(smsServiceProvider);
      final SmsPermissionState permission = await service.checkPermission();
      final bool notifications = await service.checkNotificationPermission();
      state = state.copyWith(
        permission: permission,
        notificationsEnabled: notifications,
        isCheckingPermission: false,
      );
    } catch (_) {
      state = state.copyWith(isCheckingPermission: false);
    }
  }

  /// Shows the OS dialog. Returns the resulting permission state.
  Future<SmsPermissionState> requestPermission() async {
    state = state.copyWith(isCheckingPermission: true, clearError: true);

    try {
      final SmsService service = ref.read(smsServiceProvider);
      final SmsPermissionState permission = await service.requestPermission();

      // The alert is a separate Android 13+ permission. Declining it must not
      // stop inbox sync, so the result only changes the status line.
      final bool notifications = await service.requestNotificationPermission();
      state = state.copyWith(
        permission: permission,
        notificationsEnabled: notifications,
        isCheckingPermission: false,
      );
      return permission;
    } catch (error) {
      state = state.copyWith(
        isCheckingPermission: false,
        errorMessage: 'Could not request the SMS permission.',
      );
      rethrow;
    }
  }

  /// Requests only the Android 13+ notification permission. Used when SMS
  /// access is already granted but the background alert was declined.
  Future<bool> requestNotifications() async {
    final bool enabled = await ref
        .read(smsServiceProvider)
        .requestNotificationPermission();
    state = state.copyWith(notificationsEnabled: enabled);
    return enabled;
  }

  Future<bool> openSettings() => ref.read(smsServiceProvider).openSettings();

  /// Scans, uploads, and refreshes everything the new data affects.
  ///
  /// Returns the summary, or null when there is no active shop.
  Future<SmsSyncSummary?> syncNow() async {
    final shop = ref.read(activeShopProvider);
    if (shop == null) {
      state = state.copyWith(
        errorMessage: 'Create a shop before syncing messages.',
      );
      return null;
    }

    if (!state.permission.isGranted) {
      state = state.copyWith(
        errorMessage: 'Grant the message permission first — syncing needs it.',
      );
      return null;
    }

    state = state.copyWith(isSyncing: true, clearError: true);

    try {
      final SmsService service = ref.read(smsServiceProvider);
      final SmsInboxScan scan = await service.scanInbox();

      final SmsSyncSummary summary = await service.syncShop(shopId: shop.id);
      final DateTime now = DateTime.now();

      await ref
          .read(sharedPreferencesProvider)
          .setInt(_lastSyncKey, now.millisecondsSinceEpoch);

      state = state.copyWith(
        isSyncing: false,
        lastSyncedAt: now,
        lastSummary: summary,
        lastScan: scan,
      );

      // New transactions change the score, the cash flow, and the profile.
      // Refreshing here means the Finance tab is already correct when the user
      // switches to it — no stale numbers after the flagship flow.
      ref.invalidate(monthTransactionsProvider);
      ref.invalidate(recentTransactionsProvider);
      ref.invalidate(financeInsightsProvider);
      ref.invalidate(recentSmsPaymentsProvider);
      ref.invalidate(smsPaymentHistoryProvider);
      ref.invalidate(creditProfileProvider);
      ref.invalidate(matchedPlansProvider);
      ref.invalidate(productListProvider);

      return summary;
    } catch (error) {
      state = state.copyWith(
        isSyncing: false,
        errorMessage: _messageFor(error),
      );
      rethrow;
    }
  }

  /// Uploads one message the phone captured live.
  ///
  /// Failure is deliberately silent. The prompt is still useful offline, and
  /// the next inbox sync will pick the message up from the device anyway.
  Future<void> ingestLive(LiveSmsPayment payment) async {
    final shop = ref.read(activeShopProvider);
    if (shop == null) return;

    try {
      await ref
          .read(smsServiceProvider)
          .ingestOne(shopId: shop.id, payment: payment);

      ref.invalidate(recentTransactionsProvider);
      ref.invalidate(recentSmsPaymentsProvider);
      ref.invalidate(smsPaymentHistoryProvider);
      ref.invalidate(monthTransactionsProvider);
      ref.invalidate(creditProfileProvider);
      ref.invalidate(productListProvider);

      // The bulk endpoint writes on the server; pull so the new row and its SMS
      // body are in SQLite before the owner opens Payments.
      unawaited(ref.read(syncServiceProvider).syncNow());
    } catch (_) {
      // The live prompt already has everything it needs from the device.
    }
  }

  void clearError() => state = state.copyWith(clearError: true);

  String _messageFor(Object error) {
    if (error is Exception) {
      return error.toString().replaceFirst('Exception: ', '');
    }
    return 'Sync failed.';
  }
}

final smsSyncControllerProvider =
    NotifierProvider<SmsSyncController, SmsSyncState>(SmsSyncController.new);
