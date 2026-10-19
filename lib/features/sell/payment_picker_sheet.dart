import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/payment_tolerance.dart';
import '../../core/theme.dart';
import '../../models/transaction.dart';
import '../../widgets/common.dart';
import '../finance/finance_controller.dart';
import '../profile/profile_controller.dart';

/// How the customer paid, plus the mobile-money reference when one was matched.
class PaymentChoice {
  const PaymentChoice({
    required this.method,
    this.reference,
    this.smsId,
    this.amountMinor,
  });

  /// cash | bkash | nagad | rocket | upay | upi | other
  final String method;
  final String? reference;

  /// What the message says arrived. Null when the owner only picked a method.
  final int? amountMinor;

  /// Server-side SMS id when a confirmation message was picked. Linking it
  /// makes the server merge the sale into that existing payment row instead of
  /// counting the money twice.
  final String? smsId;
}

/// Browse value for "every recent message", as opposed to one payment method.
const String _browseAll = 'all';

/// The payment method on an SMS-imported row, falling back to the sender name in
/// the note for rows that predate the `paymentMethod` column.
String paymentMethodFor(Transaction transaction) {
  final String? recorded = transaction.paymentMethod;
  if (recorded != null && recorded.isNotEmpty) return recorded;

  final String note = (transaction.note ?? '').toLowerCase();
  if (note.contains('bkash')) return 'bkash';
  if (note.contains('nagad')) return 'nagad';
  if (note.contains('rocket') || note.contains('dbbl')) return 'rocket';
  if (note.contains('upay') || note.contains('ucb')) return 'upay';
  if (note.contains('upi') ||
      note.contains('paytm') ||
      note.contains('phonepe') ||
      note.contains('gpay')) {
    return 'upi';
  }
  return 'other';
}

String paymentMethodLabel(String method) => switch (method) {
  'bkash' => 'bKash',
  'nagad' => 'Nagad',
  'rocket' => 'Rocket',
  'upay' => 'Upay',
  'upi' => 'UPI',
  'cash' => 'Cash',
  _ => 'Other',
};

IconData paymentMethodIcon(String method) => switch (method) {
  'bkash' || 'nagad' => Icons.wallet_outlined,
  'rocket' => Icons.rocket_launch_outlined,
  'upay' => Icons.account_balance_outlined,
  'upi' => Icons.qr_code_rounded,
  'cash' => Icons.payments_outlined,
  _ => Icons.more_horiz_rounded,
};

/// Re-scans the device inbox, uploads anything new, and re-reads the local
/// ledger.
///
/// Returns a message to show the owner, or null when the refresh worked. Both
/// the ten-minute suggestion list and the full history are refreshed, because
/// whichever one is on screen has to be current.
Future<String?> refreshPaymentMessages(WidgetRef ref) async {
  try {
    final summary = await ref
        .read(smsSyncControllerProvider.notifier)
        .syncNow();

    if (summary == null) {
      return ref.read(smsSyncControllerProvider).errorMessage ??
          'Could not read new messages. Check the SMS permission in Profile.';
    }

    ref.invalidate(recentSmsPaymentsProvider);
    ref.invalidate(smsPaymentHistoryProvider);
    await Future.wait(<Future<List<Transaction>>>[
      ref.read(recentSmsPaymentsProvider.future),
      ref.read(smsPaymentHistoryProvider.future),
    ]);
    return null;
  } catch (error) {
    return error is ApiException
        ? error.userMessage
        : 'Could not refresh payment messages.';
  }
}

/// Payment confirmation for a mobile-money sale.
///
/// Step one lists the messages that arrived in the last ten minutes, because a
/// confirmation lands a minute or two after the customer pays. Step two —
/// reached by tapping *Look further back* or by choosing a method by hand —
/// lists every inbound message from the last 30 days so any earlier payment can
/// still be attached to the sale instead of being counted twice.
///
/// Refreshing re-scans the device inbox, uploads any new messages, and re-reads
/// the cache — so a payment that arrived a minute ago can be picked without
/// leaving the sale.
class PaymentPickerSheet extends ConsumerStatefulWidget {
  const PaymentPickerSheet({super.key, required this.totalMinor});

  final int totalMinor;

  static Future<PaymentChoice?> show(
    BuildContext context, {
    required int totalMinor,
  }) {
    return showModalBottomSheet<PaymentChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => PaymentPickerSheet(totalMinor: totalMinor),
    );
  }

  @override
  ConsumerState<PaymentPickerSheet> createState() => _PaymentPickerSheetState();
}

class _PaymentPickerSheetState extends ConsumerState<PaymentPickerSheet> {
  bool _refreshing = false;
  String? _refreshError;

  /// Null on the suggestion step. Otherwise [_browseAll] or a payment method,
  /// which switches the sheet to the full message list.
  String? _browse;

  static const List<({String value, String label, IconData icon})> _manual =
      <({String value, String label, IconData icon})>[
        (value: 'bkash', label: 'bKash', icon: Icons.wallet_outlined),
        (value: 'nagad', label: 'Nagad', icon: Icons.wallet_outlined),
        (value: 'rocket', label: 'Rocket', icon: Icons.rocket_launch_outlined),
        (value: 'upay', label: 'Upay', icon: Icons.account_balance_outlined),
        (value: 'upi', label: 'UPI', icon: Icons.qr_code_rounded),
        (value: 'other', label: 'Other', icon: Icons.more_horiz_rounded),
      ];

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });

    final String? error = await refreshPaymentMessages(ref);
    if (!mounted) return;

    setState(() {
      _refreshing = false;
      _refreshError = error;
    });
  }

  /// The closest amounts first, newest first inside each band.
  ///
  /// Ordering the exact match (and then the payments that include the cash-out
  /// charge) above the rest is what lets the owner confirm a sale without
  /// reading every row.
  List<Transaction> _closestFirst(List<Transaction> rows) {
    int rank(Transaction transaction) => switch (PaymentAmountMatch(
      receivedMinor: transaction.amountMinor,
      expectedMinor: widget.totalMinor,
      currency: transaction.currency,
    ).fit) {
      PaymentAmountFit.exact => 0,
      PaymentAmountFit.cashOut => 1,
      PaymentAmountFit.outside => 2,
    };

    return List<Transaction>.of(rows)..sort((Transaction a, Transaction b) {
      final int byRank = rank(a) - rank(b);
      return byRank != 0 ? byRank : b.occurredAt.compareTo(a.occurredAt);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? browse = _browse;

    // Step two: the owner asked to pick the message themselves.
    if (browse != null) {
      return _PickMessageStep(
        totalMinor: widget.totalMinor,
        browse: browse,
        onBack: () => setState(() => _browse = null),
      );
    }

    final int toleranceMinor = paymentToleranceMinor(widget.totalMinor);
    final AsyncValue<List<Transaction>> payments = ref.watch(
      recentSmsPaymentsProvider,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Mobile money payment',
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
            Text(
              'Looking for ${formatMinor(widget.totalMinor)} in the payment '
              'messages from the last ${kSmsSuggestionWindow.inMinutes} '
              'minutes. Cash-out charges vary by around '
              '${formatMinorCompact(toleranceMinor)}, so a payment inside that '
              'difference still counts.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Text('Payment messages', style: theme.textTheme.labelLarge),
                const Spacer(),
                if (_refreshing)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            if (_refreshError != null) ...<Widget>[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _refreshError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            AsyncSection<List<Transaction>>(
              value: payments,
              compact: true,
              loadingMessage: 'Checking recent payment messages',
              onRetry: () => ref.invalidate(recentSmsPaymentsProvider),
              builder: (List<Transaction> rows) {
                if (rows.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'No payment in the last '
                          '${kSmsSuggestionWindow.inMinutes} minutes.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'The customer may have paid a little earlier, or the '
                          'confirmation has not landed yet. Tap Refresh, look '
                          'further back, or pick the method below.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _browse = _browseAll),
                            icon: const Icon(Icons.history_rounded, size: 16),
                            label: const Text('Look further back'),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final List<Transaction> ranked = _closestFirst(rows);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final Transaction transaction in ranked)
                      _PaymentCandidate(
                        transaction: transaction,
                        match: PaymentAmountMatch(
                          receivedMinor: transaction.amountMinor,
                          expectedMinor: widget.totalMinor,
                          currency: transaction.currency,
                        ),
                        onTap: () => Navigator.of(context).pop(
                          PaymentChoice(
                            method: paymentMethodFor(transaction),
                            reference: transaction.reference,
                            smsId: transaction.smsId,
                            amountMinor: transaction.amountMinor,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _browse = _browseAll),
                        icon: const Icon(Icons.history_rounded, size: 16),
                        label: const Text('Look further back'),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: Divider(color: theme.colorScheme.outlineVariant),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'or choose the method',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Divider(color: theme.colorScheme.outlineVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final ({String value, String label, IconData icon}) method
                    in _manual)
                  ActionChip(
                    avatar: Icon(method.icon, size: 16),
                    label: Text(method.label),
                    // Opens the full message list, so the payment can be
                    // attached instead of being recorded twice.
                    onPressed: () => setState(() => _browse = method.value),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Picking a method shows your recent payment messages, so you can '
              'attach the one that matches this sale.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Cash is the other side of the confirm bar: close this sheet and '
              'swipe right.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentCandidate extends StatelessWidget {
  const _PaymentCandidate({
    required this.transaction,
    required this.match,
    required this.onTap,
  });

  final Transaction transaction;

  /// The message amount compared with the sale total, so the row can say why it
  /// is being offered.
  final PaymentAmountMatch match;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String method = paymentMethodFor(transaction);
    final String methodLabel = paymentMethodLabel(method);
    final IconData icon = paymentMethodIcon(method);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 18,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  icon,
                  size: 18,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          methodLabel,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (match.isExact) ...<Widget>[
                          const SizedBox(width: 6),
                          const StatusChip(
                            label: 'Matches total',
                            color: GreenBizTheme.inflow,
                            dense: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${relativeTime(transaction.occurredAt)}'
                      '${transaction.reference == null ? '' : ' · ${transaction.reference}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (match.fit == PaymentAmountFit.cashOut) ...<Widget>[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: StatusChip(
                          label: match.cashOutLabel,
                          color: GreenBizTheme.scoreMedium,
                          dense: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatMinor(
                  transaction.amountMinor,
                  currency: transaction.currency,
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Step two of the payment sheet: the owner picks the message themselves.
///
/// Reached from *Look further back* (every inbound message) or from a manual
/// method chip (same list, plus a way to record the method with no message).
/// The list is always newest first, with Refresh to scan messages that just
/// arrived while the sheet was open.
class _PickMessageStep extends ConsumerStatefulWidget {
  const _PickMessageStep({
    required this.totalMinor,
    required this.browse,
    required this.onBack,
  });

  final int totalMinor;

  /// [_browseAll] for every message, or a payment method picked by hand.
  final String browse;

  final VoidCallback onBack;

  @override
  ConsumerState<_PickMessageStep> createState() => _PickMessageStepState();
}

class _PickMessageStepState extends ConsumerState<_PickMessageStep> {
  bool _refreshing = false;
  String? _refreshError;

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });

    final String? error = await refreshPaymentMessages(ref);
    if (!mounted) return;

    setState(() {
      _refreshing = false;
      _refreshError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool pickedMethod = widget.browse != _browseAll;
    final String methodLabel = pickedMethod
        ? paymentMethodLabel(widget.browse)
        : 'payment';
    final AsyncValue<List<Transaction>> payments = ref.watch(
      smsPaymentHistoryProvider,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: 'Back',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    pickedMethod
                        ? 'Attach a $methodLabel payment'
                        : 'Payment messages',
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
            Text(
              pickedMethod
                  ? 'Tap the message that confirms this $methodLabel payment '
                        'of ${formatMinor(widget.totalMinor)}, or record it '
                        'without one.'
                  : 'Every inbound payment message from the last '
                        '${kSmsHistoryWindow.inDays} days, newest first. Tap '
                        'the one that paid ${formatMinor(widget.totalMinor)}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Text('Payment messages', style: theme.textTheme.labelLarge),
                const Spacer(),
                if (_refreshing)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                TextButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            if (_refreshError != null) ...<Widget>[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _refreshError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            AsyncSection<List<Transaction>>(
              value: payments,
              compact: true,
              loadingMessage: 'Checking payment messages',
              onRetry: () => ref.invalidate(smsPaymentHistoryProvider),
              builder: (List<Transaction> rows) {
                if (rows.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'No inbound payment message in the last '
                      '${kSmsHistoryWindow.inDays} days.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final Transaction transaction in rows)
                      _PaymentCandidate(
                        transaction: transaction,
                        match: PaymentAmountMatch(
                          receivedMinor: transaction.amountMinor,
                          expectedMinor: widget.totalMinor,
                          currency: transaction.currency,
                        ),
                        onTap: () => Navigator.of(context).pop(
                          PaymentChoice(
                            method: paymentMethodFor(transaction),
                            reference: transaction.reference,
                            smsId: transaction.smsId,
                            amountMinor: transaction.amountMinor,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (pickedMethod) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(context)
                        .pop(PaymentChoice(method: widget.browse)),
                icon: Icon(paymentMethodIcon(widget.browse), size: 18),
                label: Text('Use $methodLabel without a message'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
