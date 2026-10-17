import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../models/transaction.dart';
import '../../widgets/common.dart';
import '../auth/auth_controller.dart';
import '../sync/sync_controller.dart';
import 'finance_controller.dart';

/// The payment ledger: manual entries and everything imported from SMS.
///
/// Swipe right to mark a row as business, swipe left to mark it personal.
/// Personal rows remain in the list (nothing is hidden) but are excluded from
/// the cash-flow totals and the credit score.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

enum _PaymentFilter { all, sms, manual, personal }

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  _PaymentFilter _filter = _PaymentFilter.all;

  List<Transaction> _filtered(List<Transaction> rows) => switch (_filter) {
    _PaymentFilter.all => rows,
    _PaymentFilter.sms =>
      rows.where((Transaction tx) => tx.smsId != null).toList(growable: false),
    _PaymentFilter.manual =>
      rows.where((Transaction tx) => tx.smsId == null).toList(growable: false),
    _PaymentFilter.personal =>
      rows.where((Transaction tx) => !tx.isBusiness).toList(growable: false),
  };

  Future<void> _setBusiness(Transaction transaction, bool isBusiness) async {
    if (transaction.isBusiness == isBusiness) return;

    try {
      await ref
          .read(transactionServiceProvider)
          .setBusiness(transaction.id, isBusiness);

      if (!mounted) return;
      showAppMessage(
        context,
        isBusiness
            ? 'Marked as business. It counts toward your sales and score.'
            : 'Marked as personal. It is excluded from business totals and '
                  'your score.',
      );
    } catch (error) {
      if (!mounted) return;
      showErrorMessage(context, error);
    }
  }

  Future<void> _showMessage(Transaction transaction) async {
    final ThemeData theme = Theme.of(context);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.sms_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Payment message',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    transaction.signedAmountLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: transaction.isInflow
                          ? GreenBizTheme.inflow
                          : GreenBizTheme.outflow,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${transaction.smsSender ?? 'Unknown sender'} · '
                '${DateFormat('d MMM yyyy, h:mm a').format(transaction.occurredAt.toLocal())}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.55,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: transaction.hasSmsMessage
                    ? SelectableText(
                        transaction.smsBody!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                        ),
                      )
                    : Text(
                        'The message text has not synced to this phone yet. '
                        'Pull down to refresh, or sync from Profile.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              if (transaction.reference != null) ...<Widget>[
                const SizedBox(height: 12),
                DetailRow(label: 'TrxID', value: transaction.reference!),
              ],
              const SizedBox(height: 12),
              DetailRow(
                label: 'Payment method',
                value: transaction.paymentMethodLabel,
              ),
              DetailRow(
                label: 'Recorded as',
                value: transaction.isBusiness ? 'Business' : 'Personal',
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showActions(Transaction transaction) async {
    final bool? isBusiness = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(transaction.counterpartyLabel),
              subtitle: Text(
                transaction.isFromSms ? 'Imported from SMS' : 'Manual entry',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.storefront_rounded),
              title: const Text('Mark as business'),
              selected: transaction.isBusiness,
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('Mark as personal'),
              selected: !transaction.isBusiness,
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );

    if (isBusiness != null) await _setBusiness(transaction, isBusiness);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final shop = ref.watch(activeShopProvider);
    final AsyncValue<TransactionPage> payments = ref.watch(
      recentTransactionsProvider,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payments'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Sync now',
            onPressed: () =>
                ref.read(syncControllerProvider.notifier).syncNow(),
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: shop == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No shop yet',
              message: 'Create a shop to see its payment records.',
            )
          : RefreshIndicator(
              onRefresh: () =>
                  ref.read(syncControllerProvider.notifier).syncNow(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: <Widget>[
                  const _SwipeHintCard(),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final _PaymentFilter option in _PaymentFilter.values)
                        ChoiceChip(
                          label: Text(_labelFor(option)),
                          selected: _filter == option,
                          onSelected: (_) => setState(() => _filter = option),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AsyncSection<TransactionPage>(
                    value: payments,
                    loadingMessage: 'Loading your payments',
                    onRetry: () => ref.invalidate(recentTransactionsProvider),
                    builder: (TransactionPage page) {
                      final List<Transaction> rows = _filtered(
                        page.transactions,
                      );

                      if (rows.isEmpty) {
                        return EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: _filter == _PaymentFilter.all
                              ? 'No payments yet'
                              : 'Nothing in this filter',
                          message:
                              'SMS payment confirmations and manual entries '
                              'appear here. Swipe a row to mark it personal.',
                        );
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            '${rows.length} payment'
                            '${rows.length == 1 ? '' : 's'} · last 90 days',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          for (final Transaction transaction in rows)
                            Dismissible(
                              key: ValueKey<String>(transaction.id),
                              direction: DismissDirection.horizontal,
                              background: const _SwipeBackground(
                                alignment: Alignment.centerLeft,
                                color: GreenBizTheme.inflow,
                                icon: Icons.storefront_rounded,
                                label: 'Business',
                              ),
                              secondaryBackground: const _SwipeBackground(
                                alignment: Alignment.centerRight,
                                color: GreenBizTheme.scoreMedium,
                                icon: Icons.person_outline_rounded,
                                label: 'Personal',
                              ),
                              confirmDismiss: (DismissDirection direction) async {
                                await _setBusiness(
                                  transaction,
                                  direction == DismissDirection.startToEnd,
                                );
                                // Never remove the row: this is a toggle, not a
                                // delete.
                                return false;
                              },
                              child: _PaymentTile(
                                transaction: transaction,
                                onTap: transaction.isFromSms
                                    ? () => _showMessage(transaction)
                                    : null,
                                onLongPress: () => _showActions(transaction),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }

  String _labelFor(_PaymentFilter filter) => switch (filter) {
    _PaymentFilter.all => 'All',
    _PaymentFilter.sms => 'SMS',
    _PaymentFilter.manual => 'Manual',
    _PaymentFilter.personal => 'Personal',
  };
}

class _SwipeHintCard extends StatelessWidget {
  const _SwipeHintCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.swipe_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Swipe right for business, left for personal. Long-press for the '
              'same actions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({
    required this.transaction,
    required this.onTap,
    required this.onLongPress,
  });

  final Transaction transaction;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool inflow = transaction.isInflow;
    final Color amountColor = inflow
        ? GreenBizTheme.inflow
        : GreenBizTheme.outflow;

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    inflow
                        ? Icons.south_west_rounded
                        : Icons.north_east_rounded,
                    size: 18,
                    color: amountColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      transaction.counterpartyLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    transaction.signedAmountLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: amountColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      DateFormat('d MMM yyyy, h:mm a')
                          .format(transaction.occurredAt.toLocal()),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (transaction.isPending)
                    const StatusChip(
                      label: 'Waiting to sync',
                      color: GreenBizTheme.scoreMedium,
                      icon: Icons.cloud_upload_outlined,
                      dense: true,
                    )
                  else if (transaction.hasSyncFailed)
                    StatusChip(
                      label: 'Sync failed',
                      color: theme.colorScheme.error,
                      icon: Icons.sync_problem_rounded,
                      dense: true,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  StatusChip(
                    label: transaction.isFromSms ? 'SMS' : 'Manual',
                    color: transaction.isFromSms
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    icon: transaction.isFromSms
                        ? Icons.sms_outlined
                        : Icons.edit_outlined,
                    dense: true,
                  ),
                  StatusChip(
                    label: transaction.isBusiness ? 'Business' : 'Personal',
                    color: transaction.isBusiness
                        ? GreenBizTheme.inflow
                        : GreenBizTheme.scoreMedium,
                    icon: transaction.isBusiness
                        ? Icons.storefront_outlined
                        : Icons.person_outline_rounded,
                    dense: true,
                  ),
                  if (transaction.paymentMethod != null)
                    StatusChip(
                      label: transaction.paymentMethodLabel,
                      color: theme.colorScheme.secondary,
                      icon: Icons.account_balance_wallet_outlined,
                      dense: true,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
