import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/theme.dart';
import '../../../models/credit_profile.dart';
import '../../../widgets/common.dart';
import '../finance_controller.dart';

/// Card 2 - the credit score, the four factors behind it, and the risk flags.
///
/// Everything on this card is shown with its reasoning: a score a shop owner
/// cannot interrogate is a score they cannot improve.
class CreditScoreCard extends ConsumerStatefulWidget {
  const CreditScoreCard({super.key});

  @override
  ConsumerState<CreditScoreCard> createState() => _CreditScoreCardState();
}

class _CreditScoreCardState extends ConsumerState<CreditScoreCard> {
  bool _isRecomputing = false;

  Future<void> _recompute() async {
    setState(() => _isRecomputing = true);
    try {
      final int? score = await ref
          .read(financeControllerProvider)
          .recomputeCredit();
      if (!mounted) return;
      showAppMessage(
        context,
        score == null
            ? 'No shop selected.'
            : 'Credit score recalculated: $score/100',
      );
    } catch (error) {
      if (!mounted) return;
      showErrorMessage(context, error);
    } finally {
      if (mounted) setState(() => _isRecomputing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<CreditProfile> profile = ref.watch(creditProfileProvider);
    final theme = Theme.of(context);

    return AppCard(
      title: 'Credit profile',
      subtitle: 'Based on the last 90 days of recorded payments',
      trailing: IconButton(
        tooltip: 'Recalculate',
        visualDensity: VisualDensity.compact,
        onPressed: _isRecomputing ? null : _recompute,
        icon: _isRecomputing
            ? const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.calculate_outlined, size: 18),
      ),
      child: AsyncSection<CreditProfile>(
        value: profile,
        loadingMessage: 'Working out your score',
        compact: true,
        onRetry: () => ref.invalidate(creditProfileProvider),
        builder: (CreditProfile data) {
          final Color bandColor = GreenBizTheme.forScore(data.score);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    height: 104,
                    width: 104,
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        SizedBox(
                          height: 104,
                          width: 104,
                          child: CircularProgressIndicator(
                            value: data.score / 100,
                            strokeWidth: 9,
                            backgroundColor: bandColor.withValues(alpha: 0.13),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              bandColor,
                            ),
                            strokeCap: StrokeCap.round,
                          ),
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Text(
                              '${data.score}',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: bandColor,
                                letterSpacing: -1,
                              ),
                            ),
                            Text(
                              'out of 100',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 10,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        StatusChip(
                          label: GreenBizTheme.labelForScore(data.score),
                          color: bandColor,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${formatMinorCompact(data.monthlyRevenueAvgMinor)} '
                          'average monthly money in',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${data.transactionCount90d} transactions · '
                          '${(data.monthlyVolatility * 100).toStringAsFixed(0)}% monthly swing',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'What shapes your score',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              ...data.factors.map(
                (CreditFactor factor) => _FactorBar(factor: factor),
              ),
              if (data.riskExplanations.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  'What to work on',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ...data.riskExplanations.map(
                  (String explanation) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            explanation,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'This is a behavioural score built from your own records. '
                'It is not a credit bureau score, and it is not a lending decision.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One weighted factor as a labelled bar, with its contribution in points.
class _FactorBar extends StatelessWidget {
  const _FactorBar({required this.factor});

  final CreditFactor factor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color color = GreenBizTheme.forScore(factor.score);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  factor.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${factor.score}/100',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${(factor.weight * 100).toStringAsFixed(0)}% weight',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: factor.score / 100,
              minHeight: 6,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${factor.label} · adds ${factor.contributionPoints} points',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
