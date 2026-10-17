import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped whenever the local database changes (a local write, or a pull from
/// the server). Providers that read from SQLite watch this value, so every
/// screen refreshes without any screen knowing about the sync engine.
class DataRevision extends Notifier<int> {
  Timer? _settleTimer;

  @override
  int build() {
    ref.onDispose(() => _settleTimer?.cancel());
    return 0;
  }

  /// Coalesces a burst of writes into one refresh.
  ///
  /// Startup can produce four local changes inside a second: the outbox drain,
  /// the pull, and two background report prefetches. Bumping for every one of
  /// them made Inventory and Finance rebuild and reload four times before the
  /// owner touched anything. A short trailing debounce means the screens see
  /// the settled state once.
  ///
  /// Use [bumpNow] when the change must be visible on the next frame, such as
  /// after the owner adds a product.
  void bump() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 350), () {
      state = state + 1;
    });
  }

  /// Skips the debounce for a user-initiated write.
  void bumpNow() {
    _settleTimer?.cancel();
    state = state + 1;
  }
}

final dataRevisionProvider = NotifierProvider<DataRevision, int>(
  DataRevision.new,
);
