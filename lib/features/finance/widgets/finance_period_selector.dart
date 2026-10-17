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

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final ({FinancePreset preset, String label}) option in _options)
          ChoiceChip(
            label: Text(option.label),
            selected: period.preset == option.preset,
            onSelected: (_) => controller.selectPreset(option.preset),
          ),
        ActionChip(
          avatar: const Icon(Icons.calendar_month_outlined, size: 16),
          label: Text(period.isCustomMonth ? period.label : 'Pick a month'),
          onPressed: () => _pickMonth(context, ref),
          backgroundColor: period.isCustomMonth
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
        ),
      ],
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
