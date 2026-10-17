import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/revision.dart';
import '../../models/credit_profile.dart';
import '../../models/plan.dart';
import '../../models/transaction.dart';
import '../../services/credit_service.dart';
import '../auth/auth_controller.dart';
import 'finance_insights.dart';
import 'finance_period.dart';

/// This month's transactions plus the server-computed in/out totals.
final monthTransactionsProvider = FutureProvider<TransactionPage>((ref) async {
  ref.watch(dataRevisionProvider);

  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return TransactionPage.empty;

  return ref.watch(transactionServiceProvider).currentMonth(shopId);
});

/// The range currently selected in the Finance overview.
final financePeriodProvider =
    NotifierProvider<FinancePeriodController, FinancePeriod>(
      FinancePeriodController.new,
    );

class FinancePeriodController extends Notifier<FinancePeriod> {
  @override
  FinancePeriod build() => FinancePeriod.thisMonth();

  void selectPreset(FinancePreset preset) {
    state = switch (preset) {
      FinancePreset.thisWeek => FinancePeriod.thisWeek(),
      FinancePreset.thisMonth => FinancePeriod.thisMonth(),
      FinancePreset.lastMonth => FinancePeriod.lastMonth(),
      FinancePreset.last90Days => FinancePeriod.last90Days(),
      FinancePreset.thisYear => FinancePeriod.thisYear(),
    };
  }

  void selectMonth(DateTime month) {
    state = FinancePeriod.monthOf(month);
  }
}

/// Business-only totals, chart buckets and breakdowns for [period].
///
/// Reads through the offline transaction service: the same cached ledger the
/// Payments screen uses. A range with no local rows asks the server once, which
/// is why opening a month the phone has never displayed still works online.
final financeInsightsProvider =
    FutureProvider.family<FinanceSummary, FinancePeriod>((ref, period) async {
      ref.watch(dataRevisionProvider);

      final shopId = ref.watch(activeShopIdProvider);
      if (shopId == null) return FinanceSummary.empty(period);

      final service = ref.watch(transactionServiceProvider);

      final TransactionPage current = await service.listForShop(
        shopId,
        from: period.start,
        to: period.end,
        businessOnly: true,
        limit: 5000,
        prefetchRemote: true,
      );
      final TransactionPage previous = await service.listForShop(
        shopId,
        from: period.previousStart,
        to: period.previousEnd,
        businessOnly: true,
        limit: 5000,
        prefetchRemote: true,
      );

      return FinanceSummary.build(
        period: period,
        rows: current.transactions,
        previousRows: previous.transactions,
      );
    });

/// The last 90 days of payments, business and personal, for the payments list.
///
/// This is the credit-scoring window, so the list and the score are looking at
/// the same period. Older rows stay on the server and in the cached ledger.
final recentTransactionsProvider = FutureProvider<TransactionPage>((ref) async {
  ref.watch(dataRevisionProvider);

  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return TransactionPage.empty;

  return ref
      .watch(transactionServiceProvider)
      .listForShop(
        shopId,
        from: DateTime.now().subtract(const Duration(days: 90)),
        limit: 500,
      );
});

/// How far back the sale payment picker looks for a confirmation message.
///
/// A bKash/Nagad/Rocket/UPI confirmation lands within a minute or two of the
/// customer paying, so a hit from yesterday is almost always a different sale.
/// Anything older is one tap away through [smsPaymentHistoryProvider].
const Duration kSmsSuggestionWindow = Duration(minutes: 10);

/// How far back the full "attach a payment message" list reaches.
const Duration kSmsHistoryWindow = Duration(days: 30);

/// Inbound SMS-imported payments inside [window], newest first.
///
/// Ordered explicitly by time so a message that arrived while the owner was
/// talking to the customer always reads at the top of the list.
Future<List<Transaction>> _smsPayments(
  Ref ref, {
  required Duration window,
  required int limit,
}) async {
  ref.watch(dataRevisionProvider);

  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return const <Transaction>[];

  final TransactionPage page = await ref
      .watch(transactionServiceProvider)
      .listForShop(
        shopId,
        from: DateTime.now().subtract(window),
        direction: 'in',
        limit: limit,
      );

  final List<Transaction> rows = page.transactions
      .where((Transaction transaction) => transaction.isFromSms)
      .toList(growable: false);

  rows.sort(
    (Transaction a, Transaction b) => b.occurredAt.compareTo(a.occurredAt),
  );
  return rows;
}

/// Inbound SMS payments from the last [kSmsSuggestionWindow], newest first.
///
/// The suggestion list on the sale payment sheet. Ten minutes is long enough to
/// cover a slow confirmation and short enough that a payment from yesterday
/// never looks like it belongs to the sale being confirmed.
final recentSmsPaymentsProvider = FutureProvider<List<Transaction>>(
  (Ref ref) => _smsPayments(ref, window: kSmsSuggestionWindow, limit: 25),
);

/// Every inbound SMS payment from the last [kSmsHistoryWindow], newest first.
///
/// Shown when the owner picks a payment method by hand, or asks to look further
/// back than the ten-minute window, so an earlier payment can still be attached
/// to the sale instead of being counted twice.
final smsPaymentHistoryProvider = FutureProvider<List<Transaction>>(
  (Ref ref) => _smsPayments(ref, window: kSmsHistoryWindow, limit: 200),
);

/// The credit profile for the active shop.
///
/// The server creates the profile lazily on first read, so a brand-new shop gets
/// a real 0-100 number with risk flags rather than an empty card. Offline, the
/// last profile is served from SQLite.
final creditProfileProvider = FutureProvider<CreditProfile>((ref) async {
  ref.watch(dataRevisionProvider);

  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return CreditProfile.empty;

  return ref.watch(creditServiceProvider).get(shopId);
});

/// Loan plans ranked against the shop's recorded business revenue.
final matchedPlansProvider = FutureProvider<MatchResult>((ref) async {
  ref.watch(dataRevisionProvider);

  final shopId = ref.watch(activeShopIdProvider);
  if (shopId == null) return MatchResult.empty;

  return ref.watch(creditServiceProvider).matchedPlans(shopId);
});

/// The public plan directory, shown when the shop has no matched plans yet.
final planDirectoryProvider = FutureProvider<List<Plan>>((ref) async {
  ref.watch(dataRevisionProvider);

  return ref.watch(creditServiceProvider).directory();
});

/// Whether the Worker has an AI provider configured.
///
/// Used to decide whether to offer the AI advice button at all, instead of
/// letting the user tap it and get an error.
final aiAvailabilityProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.watch(aiServiceProvider).isAvailable();
  } catch (_) {
    // A health probe must not break the tab. Treat "unknown" as unavailable.
    return false;
  }
});

/// Writes and refreshes for the Finance tab.
class FinanceController {
  const FinanceController(this._ref);

  final Ref _ref;

  /// Reloads everything the tab shows. Used by pull-to-refresh.
  Future<void> refreshAll() async {
    _ref.invalidate(monthTransactionsProvider);
    _ref.invalidate(recentTransactionsProvider);
    _ref.invalidate(financeInsightsProvider);
    _ref.invalidate(creditProfileProvider);
    _ref.invalidate(matchedPlansProvider);

    final FinancePeriod period = _ref.read(financePeriodProvider);
    await Future.wait<void>(<Future<void>>[
      _ref.read(monthTransactionsProvider.future).then((_) {}),
      _ref.read(financeInsightsProvider(period).future).then((_) {}),
      _ref.read(creditProfileProvider.future).then((_) {}),
    ]);
  }

  /// Forces the score to be recomputed from the ledger right now.
  ///
  /// Returns the new score, or null when there is no active shop.
  Future<int?> recomputeCredit() async {
    final shopId = _ref.read(activeShopIdProvider);
    if (shopId == null) return null;

    final CreditProfile profile = await _ref
        .read(creditServiceProvider)
        .recompute(shopId);

    _ref.invalidate(creditProfileProvider);
    return profile.score;
  }
}

final financeControllerProvider = Provider<FinanceController>(
  (ref) => FinanceController(ref),
);
