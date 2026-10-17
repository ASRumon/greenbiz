import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_db.dart';
import '../../core/providers.dart';
import '../../core/revision.dart';
import '../../services/sync_service.dart';

/// Whether the app can reach the network and whether anything is waiting.
class SyncState {
  const SyncState({
    this.isOnline = true,
    this.isSyncing = false,
    this.lastSyncedAt,
    this.error,
  });

  final bool isOnline;
  final bool isSyncing;
  final DateTime? lastSyncedAt;

  /// The first error from the last attempt, if any. A permanent failure (the
  /// server rejected a queued change) is surfaced here and the row is marked
  /// failed locally rather than being deleted.
  final String? error;

  SyncState copyWith({
    bool? isOnline,
    bool? isSyncing,
    DateTime? lastSyncedAt,
    String? error,
    bool clearError = false,
  }) => SyncState(
    isOnline: isOnline ?? this.isOnline,
    isSyncing: isSyncing ?? this.isSyncing,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Owns the background sync lifecycle.
///
/// It starts on first use (the signed-in shell), retries when connectivity
/// returns, and never blocks the UI: reads always come from SQLite.
class SyncController extends Notifier<SyncState> {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _running = false;
  bool _disposed = false;

  @override
  SyncState build() {
    _subscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final bool online = results.any(
        (ConnectivityResult result) => result != ConnectivityResult.none,
      );
      final bool cameOnline = online && !state.isOnline;
      state = state.copyWith(isOnline: online);
      if (cameOnline) unawaited(syncNow());
    });

    ref.onDispose(() {
      _disposed = true;
      _subscription?.cancel();
    });

    Future<void>.microtask(_bootstrap);
    return const SyncState();
  }

  Future<void> _bootstrap() async {
    final LocalDatabase local = ref.read(localDatabaseProvider);
    final String? lastSync = await local.getMeta('last_sync');
    final int? millis = lastSync == null ? null : int.tryParse(lastSync);
    if (millis != null && _disposed) {
      // The screen that started the controller is gone; nothing to update.
      return;
    }
    if (millis != null) {
      state = state.copyWith(
        lastSyncedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      );
    }

    final bool online = await ref.read(syncServiceProvider).isOnline();
    if (_disposed) return;
    state = state.copyWith(isOnline: online);

    // Do NOT sync here. HomeShell starts the first sync when it mounts, which
    // covers both a cold launch with a stored session and a fresh sign-in.
    // Calling syncNow here as well raced with HomeShell and could run a second
    // full pull a moment later, which the owner saw as another reload.
  }

  /// Push queued work, then pull fresh server state.
  Future<void> syncNow() async {
    if (_running) return;
    if (!ref.read(apiClientProvider).hasSession) return;

    _running = true;
    state = state.copyWith(isSyncing: true, clearError: true);

    try {
      final SyncReport report = await ref.read(syncServiceProvider).syncNow();

      // SyncService calls onLocalChange once when it changed local data; that
      // debounced bump is what refreshes Inventory/Finance. Bumping here too
      // made every launch reload twice.
      state = state.copyWith(
        isSyncing: false,
        isOnline: !report.isOffline,
        lastSyncedAt: report.isOffline ? state.lastSyncedAt : DateTime.now(),
        error: report.errors.isEmpty ? null : report.errors.first,
        clearError: report.errors.isEmpty,
      );
    } catch (_) {
      state = state.copyWith(
        isSyncing: false,
        error: 'Sync failed. Your changes are saved on this phone.',
      );
    } finally {
      _running = false;
    }
  }

  void dismissError() {
    state = state.copyWith(clearError: true);
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

/// Number of queued writes. Recomputed whenever the local database changes, so
/// a sale made offline shows "1 waiting to sync" immediately.
final pendingChangesProvider = FutureProvider<int>((ref) async {
  ref.watch(dataRevisionProvider);
  return ref.watch(localDatabaseProvider).pendingCount();
});
