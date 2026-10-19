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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
                children: <Widget>[
                  // Order tells the story: what you earned, how you score,
                  // what that unlocks, and then the AI layer on top.
                  const BusinessOverviewCard(),
                  const SizedBox(height: 14),
                  const _RecentPaymentsCard(),
                  const SizedBox(height: 14),
                  const CreditScoreCard(),
                  const SizedBox(height: 14),
                  const PlanListCard(),
                  const SizedBox(height: 14),
                  _SmsSyncStatusCard(sync: sync),
                  const SizedBox(height: 14),
                  const _AiAdviceCard(),
                  const SizedBox(height: 18),
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
              for (int index = 0; index < rows.length; index++) ...<Widget>[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                _PaymentRow(transaction: rows[index]),
              ],
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.transactions),
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('See all payments'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One compact payment line: what happened, when, and how much.
class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = transaction.isInflow
        ? GreenBizTheme.inflow
        : GreenBizTheme.outflow;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).pushNamed(AppRoutes.transactions),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Row(
          children: <Widget>[
            Container(
              height: 32,
              width: 32,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                transaction.isInflow
                    ? Icons.south_west_rounded
                    : Icons.north_east_rounded,
                size: 16,
                color: accent,
              ),
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    DateFormat('d MMM, h:mm a')
                        .format(transaction.occurredAt.toLocal()),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  if (transaction.discountMinor > 0)
                    Text(
                      'Sale ${formatMinor(transaction.saleTotalMinor, currency: transaction.currency)}'
                      ' · ${formatMinor(transaction.discountMinor, currency: transaction.currency)} off',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: GreenBizTheme.scoreMedium,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  transaction.signedAmountLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                if (transaction.isFromSms ||
                    !transaction.isBusiness) ...<Widget>[
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 4,
                    runSpacing: 3,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      if (transaction.isFromSms)
                        const StatusChip(
                          label: 'SMS',
                          color: GreenBizTheme.seed,
                          dense: true,
                        ),
                      if (!transaction.isBusiness)
                        const StatusChip(
                          label: 'Personal',
                          color: GreenBizTheme.scoreMedium,
                          dense: true,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (sync.needsPermission) ...<Widget>[
            const NoticeBox(
              icon: Icons.sms_failed_outlined,
              color: GreenBizTheme.scoreMedium,
              title: 'Automatic records are off',
              message:
                  'Grant the message permission in the Profile tab to import '
                  'payment confirmations.',
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
            if (summary != null)
              NoticeBox(
                icon: Icons.check_circle_outline_rounded,
                color: GreenBizTheme.inflow,
                title: summary.headline,
                message: '${summary.detail}\n${summary.parserBreakdown}',
              )
            else
              Text(
                'Ready to sync. We read payment confirmations from bKash, Nagad, '
                'and Rocket so you don\'t have to enter them manually.',
                style: theme.textTheme.bodySmall?.copyWith(
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
                return const NoticeBox(
                  icon: Icons.smart_toy_outlined,
                  title: 'AI advice is not configured yet',
                  message:
                      'Add GEMINI_API_KEY as a Worker secret to turn this on.',
                );
              }

              return SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: shop == null
                      ? null
                      : () => AiAdviceSheet.show(context, shopId: shop.id),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Ask AI for advice'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
