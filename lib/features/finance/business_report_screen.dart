import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../models/transaction.dart';
import '../../widgets/common.dart';
import 'finance_controller.dart';
import 'finance_insights.dart';
import 'finance_period.dart';
import 'widgets/cash_flow_chart.dart';
import 'widgets/finance_period_selector.dart';

/// The full Finance report: period totals, trend, methods and top payers.
class BusinessReportScreen extends ConsumerWidget {
  const BusinessReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final FinancePeriod period = ref.watch(financePeriodProvider);
    final AsyncValue<FinanceSummary> summary = ref.watch(
      financeInsightsProvider(period),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Business overview'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(financeInsightsProvider(period));
              ref.invalidate(recentTransactionsProvider);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          const FinancePeriodSelector(),
          const SizedBox(height: 12),
          AsyncSection<FinanceSummary>(
            value: summary,
            loadingMessage: 'Adding up your business',
            onRetry: () => ref.invalidate(financeInsightsProvider(period)),
            builder: (FinanceSummary data) {
              if (data.isEmpty) {
                return EmptyState(
                  icon: Icons.insights_outlined,
                  title: 'Nothing in ${period.label.toLowerCase()}',
                  message:
                      'Record a sale or sync payment messages, then choose '
                      'another period to see your trends.',
                  action: FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pushNamed(AppRoutes.sell),
                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                    label: const Text('Record a sale'),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SummaryCard(summary: data),
                  const SizedBox(height: 12),
                  AppCard(
                    title: 'Cash flow',
                    subtitle: _chartSubtitle(data.period),
                    child: CashFlowChart(
                      buckets: data.buckets,
                      currency: data.currency,
                      height: 156,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ComparisonCard(summary: data),
                  const SizedBox(height: 12),
                  _MethodCard(summary: data),
                  const SizedBox(height: 12),
                  _TopPayersCard(summary: data),
                  const SizedBox(height: 12),
                  _PeriodPaymentsCard(summary: data),
                  const SizedBox(height: 16),
                  Text(
                    'Totals include business payments only. Swipe a payment '
                    'left in Payments to mark it personal.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _chartSubtitle(FinancePeriod period) => switch (period.bucket) {
    FinanceBucket.day => 'Day by day · ${period.label}',
    FinanceBucket.week => 'Week by week · ${period.label}',
    FinanceBucket.month => 'Month by month · ${period.label}',
  };
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool positive = summary.netMinor >= 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Net cash flow',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${positive ? '+' : '-'}'
                '${formatMinor(summary.netMinor.abs(), currency: summary.currency)}',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: positive
                      ? GreenBizTheme.inflow
                      : GreenBizTheme.outflow,
                ),
              ),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double tileWidth = (constraints.maxWidth - 10) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    _StatTile(
                      width: tileWidth,
                      label: 'Money in',
                      value: formatMinorCompact(
                        summary.inMinor,
                        currency: summary.currency,
                      ),
                      color: GreenBizTheme.inflow,
                    ),
                    _StatTile(
                      width: tileWidth,
                      label: 'Money out',
                      value: formatMinorCompact(
                        summary.outMinor,
                        currency: summary.currency,
                      ),
                      color: GreenBizTheme.outflow,
                    ),
                    _StatTile(
                      width: tileWidth,
                      label: 'Payments',
                      value: '${summary.count}',
                      color: theme.colorScheme.primary,
                    ),
                    _StatTile(
                      width: tileWidth,
                      label: 'Average sale',
                      value: formatMinorCompact(
                        summary.averageInflowMinor,
                        currency: summary.currency,
                      ),
                      color: theme.colorScheme.secondary,
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
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.width,
    required this.label,
    required this.value,
    required this.color,
  });

  final double width;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      title: 'Compared with the previous period',
      subtitle:
          'Same length, ${DateFormat('d MMM').format(summary.period.previousStart)}'
          ' – ${DateFormat('d MMM').format(summary.period.previousEnd)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ComparisonRow(
            label: 'Money in',
            current: formatMinorCompact(
              summary.inMinor,
              currency: summary.currency,
            ),
            previous: formatMinorCompact(
              summary.previousInMinor,
              currency: summary.currency,
            ),
            percent: summary.inChangePercent,
            positiveIsGood: true,
          ),
          const SizedBox(height: 12),
          _ComparisonRow(
            label: 'Money out',
            current: formatMinorCompact(
              summary.outMinor,
              currency: summary.currency,
            ),
            previous: formatMinorCompact(
              summary.previousOutMinor,
              currency: summary.currency,
            ),
            percent: summary.outChangePercent,
            positiveIsGood: false,
          ),
          if (!summary.hasPrevious) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'There were no business payments in the previous period, so '
              'there is nothing to compare with yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow({
    required this.label,
    required this.current,
    required this.previous,
    required this.percent,
    required this.positiveIsGood,
  });

  final String label;
  final String current;
  final String previous;
  final double? percent;
  final bool positiveIsGood;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool? good = percent == null
        ? null
        : (percent! >= 0) == positiveIsGood;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'was $previous',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Text(
          current,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        if (percent == null)
          const StatusChip(label: 'No data', color: Colors.grey, dense: true)
        else
          StatusChip(
            label: '${percent! >= 0 ? '+' : ''}${percent!.toStringAsFixed(1)}%',
            color: good! ? GreenBizTheme.inflow : GreenBizTheme.scoreMedium,
            icon: percent! >= 0
                ? Icons.trending_up_rounded
                : Icons.trending_down_rounded,
            dense: true,
          ),
      ],
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int totalIn = summary.inMinor;
    final int total = totalIn > 0
        ? totalIn
        : summary.methods.fold<int>(
            0,
            (int sum, FinanceMethodSummary method) => sum + method.inMinor,
          );

    return AppCard(
      title: 'Where the money came in',
      subtitle: 'By payment method',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (
            int index = 0;
            index < summary.methods.length;
            index++
          ) ...<Widget>[
            if (index > 0) const SizedBox(height: 12),
            _MethodRow(
              method: summary.methods[index],
              totalInMinor: total,
              currency: summary.currency,
            ),
          ],
          if (summary.methods.isEmpty)
            Text(
              'No business payments in this period.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.method,
    required this.totalInMinor,
    required this.currency,
  });

  final FinanceMethodSummary method;
  final int totalInMinor;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double share = totalInMinor <= 0
        ? 0
        : (method.inMinor / totalInMinor).clamp(0, 1).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                method.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${formatMinorCompact(method.inMinor, currency: currency)} in',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(share * 100).round()}%',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: share,
            minHeight: 7,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        if (method.outMinor > 0) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            '${formatMinor(method.outMinor, currency: currency)} paid out',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }
}

class _TopPayersCard extends StatelessWidget {
  const _TopPayersCard({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      title: 'Top payers',
      subtitle: 'Where your money came from',
      child: summary.topCounterparties.isEmpty
          ? Text(
              'No incoming business payments in this period.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: <Widget>[
                for (
                  int index = 0;
                  index < summary.topCounterparties.length;
                  index++
                )
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          radius: 13,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Text(
                            '${index + 1}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                summary.topCounterparties[index].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${summary.topCounterparties[index].count} '
                                'payment${summary.topCounterparties[index].count == 1 ? '' : 's'}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          formatMinorCompact(
                            summary.topCounterparties[index].inMinor,
                            currency: summary.currency,
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: GreenBizTheme.inflow,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PeriodPaymentsCard extends StatelessWidget {
  const _PeriodPaymentsCard({required this.summary});

  final FinanceSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Transaction> rows = summary.transactions
        .take(12)
        .toList(growable: false);

    return AppCard(
      title: 'Payments in this period',
      subtitle:
          '${summary.count} business payment'
          '${summary.count == 1 ? '' : 's'} · newest first',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final Transaction row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  Icon(
                    row.isInflow
                        ? Icons.south_west_rounded
                        : Icons.north_east_rounded,
                    size: 15,
                    color: row.isInflow
                        ? GreenBizTheme.inflow
                        : GreenBizTheme.outflow,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          row.counterpartyLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          DateFormat('d MMM, h:mm a')
                              .format(row.occurredAt.toLocal()),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (row.isFromSms)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: StatusChip(
                        label: 'SMS',
                        color: GreenBizTheme.seed,
                        dense: true,
                      ),
                    ),
                  Text(
                    row.signedAmountLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: row.isInflow
                          ? GreenBizTheme.inflow
                          : GreenBizTheme.outflow,
                    ),
                  ),
                ],
              ),
            ),
          if (summary.count > rows.length) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Showing the newest ${rows.length} of ${summary.count}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.transactions),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('Open all payments'),
          ),
        ],
      ),
    );
  }
}
