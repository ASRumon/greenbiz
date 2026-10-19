import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/router.dart';
import '../../../core/theme.dart';
import '../../../widgets/common.dart';
import '../finance_controller.dart';
import '../finance_insights.dart';
import '../finance_period.dart';
import 'cash_flow_chart.dart';
import 'finance_period_selector.dart';

/// Card 1 - the business at a glance for the selected range.
class BusinessOverviewCard extends ConsumerWidget {
  const BusinessOverviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final FinancePeriod period = ref.watch(financePeriodProvider);
    final AsyncValue<FinanceSummary> summary = ref.watch(
      financeInsightsProvider(period),
    );

    return AppCard(
      title: 'Business overview',
      subtitle: 'Business payments only · ${period.label}',
      trailing: IconButton(
        tooltip: 'Open the full report',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            Navigator.of(context).pushNamed(AppRoutes.businessReport),
        icon: const Icon(Icons.open_in_new_rounded, size: 18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const FinancePeriodSelector(),
          const SizedBox(height: 14),
          AsyncSection<FinanceSummary>(
            value: summary,
            compact: true,
            loadingMessage: 'Adding up your business',
            onRetry: () => ref.invalidate(financeInsightsProvider(period)),
            builder: (FinanceSummary data) {
              if (data.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'No business payments in ${period.label.toLowerCase()}. '
                      'Try another period, or record a sale.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.of(context)
                              .pushNamed(AppRoutes.transactions),
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('Open payments'),
                    ),
                  ],
                );
              }

              final List<_Fact> facts = <_Fact>[
                if (data.hasDiscount)
                  _Fact(
                    icon: Icons.local_offer_outlined,
                    label: 'Discounts given',
                    value: formatMinor(
                      data.discountMinor,
                      currency: data.currency,
                    ),
                  ),
                if (data.busiestBucket != null)
                  _Fact(
                    icon: Icons.event_available_outlined,
                    label: switch (data.period.bucket) {
                      FinanceBucket.day => 'Best day',
                      FinanceBucket.week => 'Best week',
                      FinanceBucket.month => 'Best month',
                    },
                    value:
                        '${data.busiestBucket!.label} · '
                        '${formatMinorCompact(data.busiestBucket!.inMinor, currency: data.currency)} in',
                  ),
                if (data.topMethod != null)
                  _Fact(
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Top method',
                    value:
                        '${data.topMethod!.label} · '
                        '${formatMinorCompact(data.topMethod!.inMinor, currency: data.currency)} in',
                  ),
                if (data.topCounterparties.isNotEmpty)
                  _Fact(
                    icon: Icons.person_outline_rounded,
                    label: 'Top payer',
                    value:
                        '${data.topCounterparties.first.name} · '
                        '${formatMinorCompact(data.topCounterparties.first.inMinor, currency: data.currency)}',
                  ),
              ];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _NetHero(
                    netMinor: data.netMinor,
                    currency: data.currency,
                    changePercent: data.inChangePercent,
                    previousLabel: data.hasPrevious
                        ? 'Previous period: '
                              '${formatMinorCompact(data.previousInMinor, currency: data.currency)} in · '
                              '${formatMinorCompact(data.previousOutMinor, currency: data.currency)} out'
                        : 'No business payments in the previous period.',
                  ),
                  const SizedBox(height: 10),
                  // IntrinsicHeight keeps the three tiles the same height even
                  // when one value is a single digit and another is ৳12.5k.
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: _StatTile(
                            label: 'Money in',
                            value: formatMinorCompact(
                              data.inMinor,
                              currency: data.currency,
                            ),
                            color: GreenBizTheme.inflow,
                            icon: Icons.south_west_rounded,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            label: 'Money out',
                            value: formatMinorCompact(
                              data.outMinor,
                              currency: data.currency,
                            ),
                            color: GreenBizTheme.outflow,
                            icon: Icons.north_east_rounded,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            label: 'Payments',
                            value: '${data.count}',
                            color: theme.colorScheme.primary,
                            icon: Icons.receipt_long_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: CashFlowChart(
                      buckets: data.buckets,
                      currency: data.currency,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _MethodShareBar(
                    methods: data.methods,
                    currency: data.currency,
                  ),
                  if (facts.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    _FactList(facts: facts),
                  ],
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () =>
                          Navigator.of(context)
                              .pushNamed(AppRoutes.businessReport),
                      icon: const Icon(Icons.insights_rounded, size: 18),
                      label: const Text('Open full report'),
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
}

/// The headline figure: net money in (or out) for the selected period.
class _NetHero extends StatelessWidget {
  const _NetHero({
    required this.netMinor,
    required this.currency,
    required this.changePercent,
    required this.previousLabel,
  });

  final int netMinor;
  final String currency;
  final double? changePercent;
  final String previousLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool positive = netMinor >= 0;
    final Color accent = positive
        ? GreenBizTheme.inflow
        : GreenBizTheme.outflow;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            theme.colorScheme.primaryContainer.withValues(alpha: 0.72),
            theme.colorScheme.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'NET ${positive ? 'IN' : 'OUT'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '${positive ? '+' : '-'}'
              '${formatMinor(netMinor.abs(), currency: currency)}',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: accent,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _ChangeChip(percent: changePercent, label: 'money in'),
          const SizedBox(height: 8),
          Text(
            previousLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChangeChip extends StatelessWidget {
  const _ChangeChip({required this.percent, required this.label});

  final double? percent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (percent == null) {
      return StatusChip(
        label: 'No previous data',
        color: theme.colorScheme.onSurfaceVariant,
        dense: true,
      );
    }

    final bool up = percent! >= 0;
    return StatusChip(
      label:
          '${up ? '+' : ''}${percent!.toStringAsFixed(1)}% $label vs previous',
      color: up ? GreenBizTheme.inflow : GreenBizTheme.outflow,
      icon: up ? Icons.trending_up_rounded : Icons.trending_down_rounded,
      dense: true,
    );
  }
}

/// One of the three at-a-glance numbers under the headline.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(11, 11, 11, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Container(
            height: 26,
            width: 26,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(height: 9),
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
          const SizedBox(height: 1),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// One label / value line in the "key facts" block.
class _Fact {
  const _Fact({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;
}

/// The key facts as an aligned table, so the values form a clean column
/// instead of drifting with the length of each label.
class _FactList extends StatelessWidget {
  const _FactList({required this.facts});

  final List<_Fact> facts;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      children: <Widget>[
        for (int index = 0; index < facts.length; index++) ...<Widget>[
          if (index > 0)
            Divider(
              height: 1,
              thickness: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: <Widget>[
                Icon(
                  facts[index].icon,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: Text(
                    facts[index].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    facts[index].value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A stacked share bar for incoming money, so "where did it come from?" is
/// answered visually instead of with a wall of numbers.
class _MethodShareBar extends StatelessWidget {
  const _MethodShareBar({required this.methods, required this.currency});

  final List<FinanceMethodSummary> methods;
  final String currency;

  static const List<Color> _colors = <Color>[
    Color(0xFF15653D),
    Color(0xFF00897B),
    Color(0xFF5E35B1),
    Color(0xFFEF6C00),
    Color(0xFF546E7A),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<FinanceMethodSummary> rows = methods
        .where((FinanceMethodSummary method) => method.inMinor > 0)
        .toList(growable: false);
    final int total = rows.fold<int>(
      0,
      (int sum, FinanceMethodSummary method) => sum + method.inMinor,
    );
    if (total <= 0) return const SizedBox.shrink();

    final List<FinanceMethodSummary> shown = rows
        .take(4)
        .toList(growable: false);
    final int rest = rows
        .skip(4)
        .fold<int>(0, (int sum, FinanceMethodSummary m) => sum + m.inMinor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Where the money came in',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(
              children: <Widget>[
                for (int index = 0; index < shown.length; index++)
                  Expanded(
                    flex: shown[index].inMinor < 1 ? 1 : shown[index].inMinor,
                    child: Container(color: _colors[index % _colors.length]),
                  ),
                if (rest > 0)
                  Expanded(
                    flex: rest < 1 ? 1 : rest,
                    child: Container(color: _colors.last),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 12,
          runSpacing: 5,
          children: <Widget>[
            for (int index = 0; index < shown.length; index++)
              _ShareLegend(
                color: _colors[index % _colors.length],
                label:
                    '${shown[index].label} '
                    '${((shown[index].inMinor / total) * 100).round()}%',
              ),
            if (rest > 0)
              _ShareLegend(
                color: _colors.last,
                label: 'Other ${((rest / total) * 100).round()}%',
              ),
          ],
        ),
      ],
    );
  }
}

class _ShareLegend extends StatelessWidget {
  const _ShareLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 8,
          width: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
