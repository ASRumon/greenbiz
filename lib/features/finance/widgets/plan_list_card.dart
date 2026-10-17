import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../models/plan.dart';
import '../../../services/credit_service.dart';
import '../../../widgets/common.dart';
import '../finance_controller.dart';

/// Card 3 - loan plans matched to the shop's recorded business revenue.
///
/// The server ranks real Bangladeshi bank products by how comfortably the
/// shop's average monthly revenue covers the instalment. Revenue at least 2x
/// the instalment is shown as "High priority" (the owner's rule). The estimate
/// is indicative only; the lender still checks collateral, CIB and documents.
class PlanListCard extends ConsumerWidget {
  const PlanListCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MatchResult> matches = ref.watch(matchedPlansProvider);
    final theme = Theme.of(context);

    return AppCard(
      title: 'Loan plans',
      subtitle: 'Bangladeshi SME products, matched to your recorded revenue',
      child: AsyncSection<MatchResult>(
        value: matches,
        loadingMessage: 'Checking the loan directory',
        compact: true,
        onRetry: () => ref.invalidate(matchedPlansProvider),
        builder: (MatchResult data) {
          if (data.matches.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
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
                        Icons.info_outline_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          data.message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'In the directory now',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Record a month of business sales and these products will be '
                  'ranked against your revenue.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                const _PlanDirectoryPreview(),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (data.capacity != null)
                _CapacityCard(capacity: data.capacity!),
              if (data.capacity != null) const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Ranked for your revenue',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${data.matches.length} shown',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...data.matches.map(
                (PlanMatch match) => _MatchedPlanTile(match: match),
              ),
              Text(
                'Estimates only. Lenders also check collateral, CIB history and '
                'documents that this app does not hold.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CapacityCard extends StatelessWidget {
  const _CapacityCard({required this.capacity});

  final LoanCapacity capacity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'How much you can borrow',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!capacity.hasSuggestion) ...<Widget>[
            Text(
              'Not enough recorded revenue yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              capacity.assumptions.isEmpty
                  ? 'Record business sales for at least a month, then check again.'
                  : capacity.assumptions.first,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...<Widget>[
            Text(
              '${formatMinorCompact(capacity.suggestedAmountMinor)} '
              'over ${capacity.tenorMonths} months',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'About ${formatMinorCompact(capacity.maxAffordableEmiMinor)} a '
              'month at ${capacity.interestRatePct.toStringAsFixed(2)}% p.a.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Based on ${formatMinorCompact(capacity.monthlyRevenueMinor)} '
              'average monthly business revenue, keeping the instalment at '
              'half of that.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (capacity.basis == 'indicative_benchmark') ...<Widget>[
              const SizedBox(height: 6),
              Text(
                'No bank product could be sized from your revenue yet, so this '
                'uses a 12% / 36-month benchmark.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
          if (capacity.assumptions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              capacity.assumptions.last,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanDirectoryPreview extends ConsumerWidget {
  const _PlanDirectoryPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Plan>> plans = ref.watch(planDirectoryProvider);

    return AsyncSection<List<Plan>>(
      value: plans,
      compact: true,
      loadingMessage: 'Loading the directory',
      onRetry: () => ref.invalidate(planDirectoryProvider),
      builder: (List<Plan> data) {
        if (data.isEmpty) {
          return Text(
            'The plan directory is empty. Load it with: '
            'POST /api/admin/seed using the admin token.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }

        // Show a representative handful rather than all 39: the Finance tab is
        // a summary, and the directory endpoint is there for a full browse.
        final List<Plan> preview = data.take(4).toList(growable: false);

        return Column(
          children: <Widget>[
            ...preview.map((Plan plan) => _PlanRow(plan: plan)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${data.length} products available in total',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final List<String> facts = <String>[
      if (plan.interestLabel != null) plan.interestLabel!,
      if (plan.durationLabel != null) plan.durationLabel!,
      if (plan.minAmountMinor != null && plan.maxAmountMinor != null)
        '${formatMinorCompact(plan.minAmountMinor!)}–${formatMinorCompact(plan.maxAmountMinor!)}',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  plan.planName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              StatusChip(
                label: plan.typeLabel,
                color: theme.colorScheme.primary,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            plan.institutionName ?? 'Unknown provider',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (facts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Wrap(
              spacing: 10,
              runSpacing: 2,
              children: facts
                  .map(
                    (String fact) => Text(
                      fact,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _MatchedPlanTile extends StatelessWidget {
  const _MatchedPlanTile({required this.match});

  final PlanMatch match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color priorityColor = switch (match.priority) {
      MatchPriority.high => theme.colorScheme.primary,
      MatchPriority.medium => theme.colorScheme.tertiary,
      MatchPriority.low => theme.colorScheme.outline,
      MatchPriority.unknown => theme.colorScheme.outline,
    };

    final List<String> facts = <String>[
      if (match.emiMinor != null)
        '${match.isInterestOnly ? 'Interest' : 'EMI'} '
            '${formatMinorCompact(match.emiMinor!)}/month',
      if (match.interestRatePct != null && match.tenorMonths != null)
        '${match.interestRatePct!.toStringAsFixed(2)}% · '
            '${match.tenorMonths} months',
      if (match.suggestedAmountMinor != null)
        'Suggested ${formatMinorCompact(match.suggestedAmountMinor!)}',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  match.plan.planName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(
                label: match.priority.label,
                color: priorityColor,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${match.plan.institutionName ?? 'Unknown provider'} · '
            'fit ${(match.fitScore * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (facts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 3,
              children: facts
                  .map(
                    (String fact) => Text(
                      fact,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          ...match.reasons
              .take(3)
              .map(
                (String reason) => Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('• $reason', style: theme.textTheme.bodySmall),
                ),
              ),
          if (match.requirements.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Needs: ${match.requirements.take(2).join(' · ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          ...match.warnings
              .take(2)
              .map(
                (String warning) => Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    warning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
