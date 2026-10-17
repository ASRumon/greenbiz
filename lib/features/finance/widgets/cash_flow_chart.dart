import 'package:flutter/material.dart';

import '../../../core/money.dart';
import '../../../core/theme.dart';
import '../finance_insights.dart';

/// A small grouped bar chart: money in and money out per bucket.
///
/// Built from plain widgets instead of a chart package so it works with the
/// app's existing theme, needs no extra dependency, and stays readable at the
/// 31-bar width of a month. Tapping a bar shows its exact figures.
class CashFlowChart extends StatefulWidget {
  const CashFlowChart({
    super.key,
    required this.buckets,
    required this.currency,
    this.height = 132,
  });

  final List<FinanceBucketSummary> buckets;
  final String currency;
  final double height;

  @override
  State<CashFlowChart> createState() => _CashFlowChartState();
}

class _CashFlowChartState extends State<CashFlowChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (widget.buckets.isEmpty ||
        widget.buckets.every((FinanceBucketSummary bucket) => bucket.isEmpty)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'No money recorded in this period yet. New sales and SMS payments '
          'will appear here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final int maxValue = widget.buckets.fold<int>(
      0,
      (int max, FinanceBucketSummary bucket) => [
        max,
        bucket.inMinor,
        bucket.outMinor,
      ].reduce((int a, int b) => a > b ? a : b),
    );
    final int labelStep = (widget.buckets.length / 6).ceil().clamp(1, 12);
    final FinanceBucketSummary? selected = _selected == null
        ? null
        : widget.buckets[_selected!
              .clamp(0, widget.buckets.length - 1)
              .toInt()];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            _LegendDot(color: GreenBizTheme.inflow, label: 'Money in'),
            const SizedBox(width: 14),
            _LegendDot(color: GreenBizTheme.outflow, label: 'Money out'),
            const Spacer(),
            Flexible(
              child: Text(
                selected == null
                    ? 'Peak ${formatMinorCompact(maxValue, currency: widget.currency)}'
                    : selected.label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: widget.height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (int index = 0; index < widget.buckets.length; index++)
                Expanded(
                  child: Semantics(
                    label:
                        '${widget.buckets[index].label}: in '
                        '${formatMinor(widget.buckets[index].inMinor, currency: widget.currency)}, '
                        'out '
                        '${formatMinor(widget.buckets[index].outMinor, currency: widget.currency)}',
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(
                        () => _selected = _selected == index ? null : index,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    Expanded(
                                      child: _Bar(
                                        value: widget.buckets[index].inMinor,
                                        maxValue: maxValue,
                                        color: GreenBizTheme.inflow,
                                        highlighted: _selected == index,
                                      ),
                                    ),
                                    const SizedBox(width: 1.5),
                                    Expanded(
                                      child: _Bar(
                                        value: widget.buckets[index].outMinor,
                                        maxValue: maxValue,
                                        color: GreenBizTheme.outflow,
                                        highlighted: _selected == index,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 5),
                            SizedBox(
                              height: 13,
                              child: Text(
                                index % labelStep == 0 ||
                                        index == widget.buckets.length - 1
                                    ? widget.buckets[index].label
                                          .split(' ')
                                          .first
                                    : '',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 9,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (selected != null) ...<Widget>[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    selected.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '+${formatMinorCompact(selected.inMinor, currency: widget.currency)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: GreenBizTheme.inflow,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '-${formatMinorCompact(selected.outMinor, currency: widget.currency)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: GreenBizTheme.outflow,
                    fontWeight: FontWeight.w700,
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

class _Bar extends StatelessWidget {
  const _Bar({
    required this.value,
    required this.maxValue,
    required this.color,
    required this.highlighted,
  });

  final int value;
  final int maxValue;
  final Color color;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final double height = maxValue <= 0
        ? 0
        : (value / maxValue * 92).clamp(0, 92).toDouble();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: height < 2 && value > 0 ? 2 : height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: highlighted ? 1 : 0.78),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

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
