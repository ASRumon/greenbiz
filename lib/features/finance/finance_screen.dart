import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../models/shop.dart';
import '../../models/transaction.dart';
import '../../services/sms_service.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import '../profile/profile_controller.dart';
import 'finance_controller.dart';
import 'widgets/ai_advice_sheet.dart';
import 'widgets/business_overview_card.dart';
import 'widgets/credit_score_card.dart';
import 'widgets/plan_list_card.dart';

/// Tab 2 - money, credit, plans, and advice.
class FinanceScreen extends ConsumerWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Shop? shop = ref.watch(activeShopProvider);
    final SmsSyncState sync = ref.watch(smsSyncControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finance'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh everything',
            onPressed: () => ref.read(financeControllerProvider).refreshAll(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: shop == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No shop yet',
              message:
                  'Create a shop in the Profile tab to see your cash flow and '
                  'credit profile.',
            )
          : RefreshIndicator(
              onRefresh: () => ref.read(financeControllerProvider).refreshAll(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  // Order tells the story: what you earned, how you score,
                  // what that unlocks, and then the AI layer on top.
                  const BusinessOverviewCard(),
                  const SizedBox(height: 12),
                  const _RecentPaymentsCard(),
                  const SizedBox(height: 12),
                  const CreditScoreCard(),
                  const SizedBox(height: 12),
                  const PlanListCard(),
                  const SizedBox(height: 12),
                  _SmsSyncStatusCard(sync: sync),
                  const SizedBox(height: 12),
                  const _AiAdviceCard(),
                  const SizedBox(height: 16),
                  Text(
                    'GreenBiz is a record-keeping copilot. It is not a lender, '
                    'and nothing here is an offer of credit.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Card 2 - the last few payments, with a way into the swipeable list.
///
/// SMS-imported rows are labelled, so the owner can see at a glance that the
/// automatic records are working.
class _RecentPaymentsCard extends ConsumerWidget {
  const _RecentPaymentsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final AsyncValue<TransactionPage> payments = ref.watch(
      recentTransactionsProvider,
    );

    return AppCard(
      title: 'Payments',
      subtitle: 'SMS and manual entries · swipe to mark personal',
      child: AsyncSection<TransactionPage>(
        value: payments,
        compact: true,
        loadingMessage: 'Loading your payments',
        onRetry: () => ref.invalidate(recentTransactionsProvider),
        builder: (TransactionPage page) {
          if (page.transactions.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'No payments recorded yet. Sync your SMS inbox or import a '
                  'sale to get started.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.transactions),
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('Open payments'),
                ),
              ],
            );
          }

          final List<Transaction> rows = page.transactions
              .take(5)
              .toList(growable: false);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final Transaction transaction in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        transaction.isInflow
                            ? Icons.south_west_rounded
                            : Icons.north_east_rounded,
                        size: 16,
                        color: transaction.isInflow
                            ? GreenBizTheme.inflow
                            : GreenBizTheme.outflow,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              transaction.counterpartyLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              DateFormat('d MMM, h:mm a')
                                  .format(transaction.occurredAt.toLocal()),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (transaction.isFromSms)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: StatusChip(
                            label: 'SMS',
                            color: GreenBizTheme.seed,
                            dense: true,
                          ),
                        ),
                      if (!transaction.isBusiness)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: StatusChip(
                            label: 'Personal',
                            color: GreenBizTheme.scoreMedium,
                            dense: true,
                          ),
                        ),
                      Text(
                        transaction.signedAmountLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: transaction.isInflow
                              ? GreenBizTheme.inflow
                              : GreenBizTheme.outflow,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(context).pushNamed(AppRoutes.transactions),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('See all payments'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Card 5 - whether the automatic payment records are up to date.
class _SmsSyncStatusCard extends ConsumerWidget {
  const _SmsSyncStatusCard({required this.sync});

  final SmsSyncState sync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final SmsSyncSummary? summary = sync.lastSummary;

    return AppCard(
      title: 'Payment messages',
      subtitle: 'Last synced: ${relativeTime(sync.lastSyncedAt)}',
      trailing: IconButton(
        tooltip: 'Refresh status',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            ref.read(smsSyncControllerProvider.notifier).refreshPermission(),
        icon: const Icon(Icons.sync_rounded, size: 18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (sync.needsPermission) ...<Widget>[
            Text(
              'Automatic records are off. Grant the message permission in the '
              'Profile tab to import payment confirmations.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => ref
                  .read(smsSyncControllerProvider.notifier)
                  .requestPermission(),
              icon: const Icon(Icons.sms_outlined, size: 18),
              label: const Text('Grant permission'),
            ),
          ] else ...<Widget>[
            if (summary != null) ...<Widget>[
              Text(summary.headline, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                summary.detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                summary.parserBreakdown,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else
              Text(
                'Ready to sync. We read payment confirmations from bKash, Nagad, '
                'and Rocket so you don\'t have to enter them manually.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: sync.canSync
                  ? () async {
                      try {
                        final SmsSyncSummary? result = await ref
                            .read(smsSyncControllerProvider.notifier)
                            .syncNow();
                        if (!context.mounted || result == null) return;
                        showAppMessage(
                          context,
                          '${result.headline} ${result.parserBreakdown}',
                        );
                      } catch (error) {
                        if (!context.mounted) return;
                        showErrorMessage(context, error);
                      }
                    }
                  : null,
              icon: sync.isSyncing
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(sync.isSyncing ? 'Syncing…' : 'Sync now'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Card 4 - the AI advice entry point.
class _AiAdviceCard extends ConsumerWidget {
  const _AiAdviceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<bool> available = ref.watch(aiAvailabilityProvider);
    final Shop? shop = ref.watch(activeShopProvider);
    final theme = Theme.of(context);

    return AppCard(
      title: 'AI advice',
      subtitle: 'Plain-language guidance built from your own numbers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Ask what would most improve your chances of a working capital '
            'loan, or what insurance cover suits your shop.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          AsyncSection<bool>(
            value: available,
            compact: true,
            loadingMessage: 'Checking AI availability',
            onRetry: () => ref.invalidate(aiAvailabilityProvider),
            builder: (bool isAvailable) {
              if (!isAvailable) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'AI advice is not configured on the server yet. Add '
                          'GEMINI_API_KEY as a Worker secret to enable it.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return FilledButton.icon(
                onPressed: shop == null
                    ? null
                    : () => AiAdviceSheet.show(context, shopId: shop.id),
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: const Text('Ask AI for advice'),
              );
            },
          ),
        ],
      ),
    );
  }
}
