import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../services/ai_service.dart';
import '../../../widgets/common.dart';

/// Bottom sheet that asks the Worker for plain-language advice.
///
/// The request goes to `/api/ai/recommend`, which builds the prompt server-side
/// from the shop's aggregates. The app sends the shop id and an intent, never
/// raw messages, and the AI keys stay on the Worker.
class AiAdviceSheet extends ConsumerStatefulWidget {
  const AiAdviceSheet({super.key, required this.shopId});

  static Future<void> show(BuildContext context, {required String shopId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AiAdviceSheet(shopId: shopId),
    );
  }

  final String shopId;

  @override
  ConsumerState<AiAdviceSheet> createState() => _AiAdviceSheetState();
}

class _AiAdviceSheetState extends ConsumerState<AiAdviceSheet> {
  final TextEditingController _question = TextEditingController();

  String _intent = 'loan';
  bool _isLoading = false;
  AiAdvice? _advice;
  Object? _error;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final AiAdvice advice = await ref
          .read(aiServiceProvider)
          .recommend(
            shopId: widget.shopId,
            intent: _intent,
            message: _question.text,
          );

      if (!mounted) return;
      setState(() {
        _advice = advice;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.auto_awesome_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ask AI for advice',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The advice is based on your recorded transactions, inventory '
              'value and score. Your messages and your customers\' phone '
              'numbers are never sent.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'loan',
                  label: Text('Loan'),
                  icon: Icon(Icons.account_balance_outlined, size: 16),
                ),
                ButtonSegment<String>(
                  value: 'insurance',
                  label: Text('Insurance'),
                  icon: Icon(Icons.shield_outlined, size: 16),
                ),
              ],
              selected: <String>{_intent},
              onSelectionChanged: _isLoading
                  ? null
                  : (Set<String> selection) =>
                        setState(() => _intent = selection.first),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _question,
              maxLines: 2,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Your question (optional)',
                hintText: 'How do I qualify for a bigger working capital loan?',
              ),
            ),
            const SizedBox(height: 6),
            FilledButton.icon(
              onPressed: _isLoading ? null : _ask,
              icon: _isLoading
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(_isLoading ? 'Thinking…' : 'Get advice'),
            ),
            if (_isLoading) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Trying the AI providers in order until one answers.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
              ErrorView(error: _error!, onRetry: _ask, compact: true),
            ],
            if (_advice != null) ...<Widget>[
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.tips_and_updates_outlined,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Advice',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _advice!.advice,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
              if (_advice!.capacity != null &&
                  _advice!.capacity!.hasSuggestion) ...<Widget>[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.45,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Estimated borrowing capacity: '
                    '${formatMinorCompact(_advice!.capacity!.suggestedAmountMinor)} '
                    'over ${_advice!.capacity!.tenorMonths} months '
                    '(about ${formatMinorCompact(_advice!.capacity!.maxAffordableEmiMinor)} '
                    'a month).',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                _advice!.planIds.isEmpty
                    ? 'No plan could be sized from your recorded revenue yet, so '
                          'this advice is based on your profile alone.'
                    : '${_advice!.planIds.length} plan(s) were compared for this advice.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'AI can be wrong. Use this as a second opinion, not as '
                'financial advice.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
