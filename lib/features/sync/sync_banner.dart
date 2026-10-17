import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'sync_controller.dart';

/// A thin strip above the tabs: offline, pending, syncing, or a failed change.
///
/// It never blocks interaction. Tapping it retries the sync; nothing in the app
/// relies on the banner being green to work.
class SyncBanner extends ConsumerWidget {
  const SyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SyncState sync = ref.watch(syncControllerProvider);
    final int pending = ref.watch(pendingChangesProvider).value ?? 0;

    final bool hasError = sync.error != null;

    // A routine background sync (no queued changes, online) is invisible. It
    // used to show a "Syncing your changes…" strip on every launch, which
    // appeared and disappeared before the owner did anything.
    final bool show = hasError || !sync.isOnline || pending > 0;
    if (!show) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);

    final (IconData icon, Color color, String message) = hasError
        ? (Icons.sync_problem_rounded, theme.colorScheme.error, sync.error!)
        : !sync.isOnline
        ? (
            Icons.cloud_off_rounded,
            theme.colorScheme.onSurfaceVariant,
            pending > 0
                ? 'Offline · showing saved data · $pending waiting to sync'
                : 'Offline · showing saved data',
          )
        : pending > 0
        ? (
            sync.isSyncing ? Icons.sync_rounded : Icons.cloud_upload_outlined,
            sync.isSyncing
                ? theme.colorScheme.primary
                : GreenBizTheme.scoreMedium,
            sync.isSyncing
                ? 'Syncing $pending change${pending == 1 ? '' : 's'}…'
                : '$pending change${pending == 1 ? '' : 's'} waiting to sync',
          )
        : (Icons.sync_rounded, theme.colorScheme.primary, 'Syncing…');

    final bool canRetry = !sync.isSyncing && (sync.isOnline || hasError);

    return Material(
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap: sync.isSyncing
            ? null
            : () => ref.read(syncControllerProvider.notifier).syncNow(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: <Widget>[
              if (sync.isSyncing)
                SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (hasError)
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      ref.read(syncControllerProvider.notifier).dismissError(),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else if (canRetry)
                TextButton(
                  onPressed: () =>
                      ref.read(syncControllerProvider.notifier).syncNow(),
                  child: Text(
                    sync.isOnline ? 'Sync' : 'Retry',
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
