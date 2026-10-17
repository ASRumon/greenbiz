import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/theme.dart';
import '../../../models/transaction.dart';
import '../../../widgets/common.dart';
import '../finance_controller.dart';

/// Card 1 - this month's money in, money out, and the net.
class CashFlowCard extends ConsumerWidget {
  const CashFlowCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TransactionPage> page = ref.watch(
      monthTransactionsProvider,
    );
    final theme = Theme.of(context);

    final String monthName = _monthName(DateTime.now().month);

    return AppCard(
      title: 'Cash flow',
      subtitle: '$monthName so far',
      trailing: IconButton(
        tooltip: 'Refresh',
        visualDensity: VisualDensity.compact,
        onPressed: () => ref.invalidate(monthTransactionsProvider),
        icon: const Icon(Icons.refresh_rounded, size: 18),
      ),
      child: AsyncSection<TransactionPage>(
        value: page,
        loadingMessage: 'Adding up this month',
        compact: true,
        onRetry: () => ref.invalidate(monthTransactionsProvider),
        builder: (TransactionPage data) {
          if (data.transactions.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No payments recorded this month yet. Sync your messages or add '
                'one manually to see your cash flow.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _FlowFigure(
                      label: 'Money in',
                      amountMinor: data.totalInMinor,
                      currency: data.currency,
                      color: GreenBizTheme.inflow,
                      icon: Icons.south_west_rounded,
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 46,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  Expanded(
                    child: _FlowFigure(
                      label: 'Money out',
                      amountMinor: data.totalOutMinor,
                      currency: data.currency,
                      color: GreenBizTheme.outflow,
                      icon: Icons.north_east_rounded,
                    ),
                  ),
                ],
              ),
              const Divider(height: 26),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Net this month',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '${data.netMinor >= 0 ? '+' : '-'}${formatMinor(data.netMinor.abs(), currency: data.currency)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: data.netMinor >= 0
                          ? GreenBizTheme.inflow
                          : GreenBizTheme.outflow,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${data.transactions.length} transaction${data.transactions.length == 1 ? '' : 's'} recorded',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _monthName(int month) => const <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];
}

class _FlowFigure extends StatelessWidget {
  const _FlowFigure({
    required this.label,
    required this.amountMinor,
    required this.currency,
    required this.color,
    required this.icon,
  });

  final String label;
  final int amountMinor;
  final String currency;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            formatMinor(amountMinor, currency: currency),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
