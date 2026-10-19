import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../finance_controller.dart';
import '../finance_period.dart';

/// The range chips shared by the Finance card and the full report.
class FinancePeriodSelector extends ConsumerWidget {
  const FinancePeriodSelector({super.key});

  static const List<({FinancePreset preset, String label})> _options =
      <({FinancePreset preset, String label})>[
        (preset: FinancePreset.thisWeek, label: 'This week'),
        (preset: FinancePreset.thisMonth, label: 'This month'),
        (preset: FinancePreset.lastMonth, label: 'Last month'),
        (preset: FinancePreset.last90Days, label: '3 months'),
        (preset: FinancePreset.thisYear, label: 'This year'),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FinancePeriod period = ref.watch(financePeriodProvider);
    final FinancePeriodController controller = ref.read(
      financePeriodProvider.notifier,
    );

    // One scrolling line instead of a chip cloud: the row never grows to three
    // wrapped lines, so the summary below it keeps its place on screen.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: <Widget>[
          for (final ({FinancePreset preset, String label}) option in _options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _PeriodPill(
                label: option.label,
                selected: period.preset == option.preset,
                onTap: () => controller.selectPreset(option.preset),
              ),
            ),
          _PeriodPill(
            label: period.isCustomMonth ? period.label : 'Pick a month',
            icon: Icons.calendar_month_outlined,
            selected: period.isCustomMonth,
            onTap: () => _pickMonth(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMonth(BuildContext context, WidgetRef ref) async {
    final DateTime now = DateTime.now();
    final List<DateTime> months = <DateTime>[
      for (int index = 0; index < 18; index++)
        DateTime(now.year, now.month - index),
    ];

    final DateTime? picked = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Pick a month',
                style: Theme.of(sheetContext).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            for (final DateTime month in months)
              ListTile(
                leading: const Icon(Icons.calendar_month_outlined),
                title: Text(DateFormat('MMMM yyyy').format(month)),
                onTap: () => Navigator.of(sheetContext).pop(month),
              ),
          ],
        ),
      ),
    );

    if (picked == null) return;
    ref.read(financePeriodProvider.notifier).selectMonth(picked);
  }
}

/// A single segmented pill. Filled when selected, quiet when not, so the
/// active range reads instantly without a ripple of outlined chips.
class _PeriodPill extends StatelessWidget {
  const _PeriodPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final Color foreground = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: background,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 14, color: foreground),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
