import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env.dart';
import '../../core/money.dart';
import '../../services/sms_service.dart';
import '../../widgets/common.dart';
import 'profile_controller.dart';

/// The SMS permission and sync card.
///
/// The wording here is deliberate and load-bearing. It says we read *payment
/// confirmations* and that *personal messages are never read*. It does not say
/// "monitor", "track", or "spy" — and it names the filter that makes the promise
/// true, so the claim is checkable rather than reassuring noise.
class SmsPermissionCard extends ConsumerWidget {
  const SmsPermissionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SmsSyncState sync = ref.watch(smsSyncControllerProvider);
    final theme = Theme.of(context);

    return AppCard(
      title: 'Automatic payment records',
      subtitle: 'Sync payment confirmations from your messages',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'We read payment confirmations from bKash, Nagad, and Rocket so you '
            'don\'t have to enter them manually. When one arrives, GreenBiz can '
            'open a prompt to create a sale — even if the app was closed. We '
            'never read personal messages.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),
          _StatusRow(sync: sync),
          if (sync.permission.isGranted) ...<Widget>[
            const SizedBox(height: 14),
            _LiveAlertRow(sync: sync),
          ],
          const SizedBox(height: 16),
          if (sync.needsPermission) ...<Widget>[
            if (sync.permission == SmsPermissionState.permanentlyDenied ||
                sync.permission == SmsPermissionState.restricted)
              _PermissionBlockedNotice(
                isRestricted: sync.permission == SmsPermissionState.restricted,
                onOpenSettings: () =>
                    ref.read(smsSyncControllerProvider.notifier).openSettings(),
              )
            else
              FilledButton.icon(
                onPressed: sync.isCheckingPermission
                    ? null
                    : () => _request(context, ref),
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: const Text('Grant permission'),
              ),
          ] else
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: sync.canSync ? () => _sync(context, ref) : null,
                    icon: sync.isSyncing
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(sync.isSyncing ? 'Syncing…' : 'Sync SMS now'),
                  ),
                ),
              ],
            ),
          if (sync.isSyncing) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Reading up to ${Env.smsLookbackDays} days of messages and keeping '
              'only payment confirmations from recognised senders.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (sync.errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sync.errorMessage!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (sync.lastSummary != null) ...<Widget>[
            const SizedBox(height: 16),
            _SyncSummaryView(summary: sync.lastSummary!),
          ],
          if (sync.lastScan != null &&
              sync.lastScan!.skippedNotPayment > 0) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '${sync.lastScan!.skippedNotPayment} messages on this phone were '
              'not from a payment sender and were skipped on the device. They '
              'were never uploaded.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _request(BuildContext context, WidgetRef ref) async {
    try {
      final SmsPermissionState result = await ref
          .read(smsSyncControllerProvider.notifier)
          .requestPermission();

      if (!context.mounted) return;

      switch (result) {
        case SmsPermissionState.granted:
          showAppMessage(context, 'Permission granted. You can sync now.');
        case SmsPermissionState.permanentlyDenied:
        case SmsPermissionState.restricted:
          showAppMessage(
            context,
            'The permission was blocked. Open the app settings to allow it.',
            isError: true,
          );
        case SmsPermissionState.denied:
          showAppMessage(context, 'Permission denied.', isError: true);
      }
    } catch (error) {
      if (!context.mounted) return;
      showErrorMessage(context, error);
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      final SmsSyncSummary? summary = await ref
          .read(smsSyncControllerProvider.notifier)
          .syncNow();

      if (!context.mounted) return;

      if (summary == null) {
        showAppMessage(context, 'Sync did not run.', isError: true);
        return;
      }

      showAppMessage(context, '${summary.headline} ${summary.parserBreakdown}');
    } catch (error) {
      if (!context.mounted) return;
      showErrorMessage(context, error);
    }
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.sync});

  final SmsSyncState sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (
      IconData icon,
      String label,
      Color color,
    ) = switch (sync.permission) {
      SmsPermissionState.granted => (
        Icons.verified_user_outlined,
        'Permission granted',
        theme.colorScheme.primary,
      ),
      SmsPermissionState.permanentlyDenied => (
        Icons.block_rounded,
        'Permission blocked in settings',
        theme.colorScheme.error,
      ),
      SmsPermissionState.restricted => (
        Icons.lock_outline_rounded,
        'Blocked by device policy',
        theme.colorScheme.error,
      ),
      SmsPermissionState.denied => (
        Icons.lock_open_outlined,
        'Permission not granted',
        theme.colorScheme.onSurfaceVariant,
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Last synced: ${relativeTime(sync.lastSyncedAt)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Whether the phone can show the "new payment" prompt while the app is away.
class _LiveAlertRow extends ConsumerWidget {
  const _LiveAlertRow({required this.sync});

  final SmsSyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = sync.notificationsEnabled;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            enabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            size: 18,
            color: enabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  enabled
                      ? 'Live payment alerts are on'
                      : 'Live alerts while the app is closed are off',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'A payment message opens a prompt to create a sale, '
                            'on screen or in the notification shade.'
                      : 'Without notification permission, a payment that arrives '
                            'in the background waits until you open the app.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!enabled)
            TextButton(
              onPressed: () async {
                final bool granted = await ref
                    .read(smsSyncControllerProvider.notifier)
                    .requestNotifications();
                if (!context.mounted) return;
                showAppMessage(
                  context,
                  granted
                      ? 'Live payment alerts are on.'
                      : 'Notifications stay off. You can enable them in app '
                            'settings.',
                  isError: !granted,
                );
              },
              child: const Text('Turn on'),
            ),
        ],
      ),
    );
  }
}

class _PermissionBlockedNotice extends StatelessWidget {
  const _PermissionBlockedNotice({
    required this.isRestricted,
    required this.onOpenSettings,
  });

  /// True when a device policy blocked the permission, rather than the user.
  final bool isRestricted;
  final Future<bool> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          isRestricted
              ? 'Your device administrator has blocked SMS access for this app, '
                    'so automatic sync cannot run. You can still add transactions manually.'
              : 'Android will not show the permission dialog again. Open the app '
                    'settings and allow Messages access.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => onOpenSettings(),
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Open app settings'),
        ),
      ],
    );
  }
}

class _SyncSummaryView extends StatelessWidget {
  const _SyncSummaryView({required this.summary});

  final SmsSyncSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            summary.headline,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(summary.detail, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            summary.parserBreakdown,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (summary.score != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Credit score is now ${summary.score}/100',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
