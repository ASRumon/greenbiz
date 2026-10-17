import 'package:intl/intl.dart';

import '../../models/transaction.dart';
import 'finance_period.dart';

/// One bar in the cash-flow chart.
class FinanceBucketSummary {
  const FinanceBucketSummary({
    required this.start,
    required this.end,
    required this.label,
    required this.inMinor,
    required this.outMinor,
    required this.count,
  });

  final DateTime start;
  final DateTime end;
  final String label;
  final int inMinor;
  final int outMinor;
  final int count;

  int get netMinor => inMinor - outMinor;
  bool get isEmpty => inMinor == 0 && outMinor == 0;
}

/// Money in/out grouped by payment method.
class FinanceMethodSummary {
  const FinanceMethodSummary({
    required this.method,
    required this.label,
    required this.inMinor,
    required this.outMinor,
    required this.count,
  });

  final String method;
  final String label;
  final int inMinor;
  final int outMinor;
  final int count;

  int get totalMovedMinor => inMinor + outMinor;
}

/// A payer ranked by how much came in from them.
class FinanceCounterpartySummary {
  const FinanceCounterpartySummary({
    required this.name,
    required this.inMinor,
    required this.count,
  });

  final String name;
  final int inMinor;
  final int count;
}

/// Everything the Finance overview shows for one [FinancePeriod].
class FinanceSummary {
  const FinanceSummary({
    required this.period,
    required this.inMinor,
    required this.outMinor,
    required this.count,
    required this.inflowCount,
    required this.previousInMinor,
    required this.previousOutMinor,
    required this.previousCount,
    required this.buckets,
    required this.methods,
    required this.topCounterparties,
    required this.currency,
    required this.transactions,
  });

  factory FinanceSummary.empty(FinancePeriod period) => FinanceSummary(
    period: period,
    inMinor: 0,
    outMinor: 0,
    count: 0,
    inflowCount: 0,
    previousInMinor: 0,
    previousOutMinor: 0,
    previousCount: 0,
    buckets: _bucketSkeleton(period),
    methods: const <FinanceMethodSummary>[],
    topCounterparties: const <FinanceCounterpartySummary>[],
    currency: 'BDT',
    transactions: const <Transaction>[],
  );

  factory FinanceSummary.build({
    required FinancePeriod period,
    required List<Transaction> rows,
    required List<Transaction> previousRows,
  }) {
    final List<Transaction> business = rows
        .where((Transaction row) => row.isBusiness)
        .toList(growable: false);
    final List<Transaction> previousBusiness = previousRows
        .where((Transaction row) => row.isBusiness)
        .toList(growable: false);

    final int inMinor = business
        .where((Transaction row) => row.isInflow)
        .fold<int>(0, (int sum, Transaction row) => sum + row.amountMinor);
    final int outMinor = business
        .where((Transaction row) => !row.isInflow)
        .fold<int>(0, (int sum, Transaction row) => sum + row.amountMinor);

    final int previousInMinor = previousBusiness
        .where((Transaction row) => row.isInflow)
        .fold<int>(0, (int sum, Transaction row) => sum + row.amountMinor);
    final int previousOutMinor = previousBusiness
        .where((Transaction row) => !row.isInflow)
        .fold<int>(0, (int sum, Transaction row) => sum + row.amountMinor);

    final List<FinanceBucketSummary> buckets = _buildBuckets(period, business);
    final Map<String, ({int inMinor, int outMinor, int count})> methodTotals =
        <String, ({int inMinor, int outMinor, int count})>{};

    for (final Transaction row in business) {
      final String method = effectivePaymentMethod(row);
      final current =
          methodTotals[method] ?? (inMinor: 0, outMinor: 0, count: 0);
      methodTotals[method] = (
        inMinor: current.inMinor + (row.isInflow ? row.amountMinor : 0),
        outMinor: current.outMinor + (row.isInflow ? 0 : row.amountMinor),
        count: current.count + 1,
      );
    }

    final List<FinanceMethodSummary> methods =
        <FinanceMethodSummary>[
          for (final MapEntry<String, ({int inMinor, int outMinor, int count})>
              entry
              in methodTotals.entries)
            FinanceMethodSummary(
              method: entry.key,
              label: paymentMethodLabel(entry.key),
              inMinor: entry.value.inMinor,
              outMinor: entry.value.outMinor,
              count: entry.value.count,
            ),
        ]..sort(
          (FinanceMethodSummary a, FinanceMethodSummary b) =>
              b.totalMovedMinor.compareTo(a.totalMovedMinor),
        );

    final Map<String, ({int amount, int count})> payerTotals =
        <String, ({int amount, int count})>{};
    for (final Transaction row in business.where(
      (Transaction row) => row.isInflow,
    )) {
      final String name = row.counterpartyLabel;
      final current = payerTotals[name] ?? (amount: 0, count: 0);
      payerTotals[name] = (
        amount: current.amount + row.amountMinor,
        count: current.count + 1,
      );
    }

    final List<FinanceCounterpartySummary> counterparties =
        <FinanceCounterpartySummary>[
          for (final MapEntry<String, ({int amount, int count})> entry
              in payerTotals.entries)
            FinanceCounterpartySummary(
              name: entry.key,
              inMinor: entry.value.amount,
              count: entry.value.count,
            ),
        ]..sort(
          (FinanceCounterpartySummary a, FinanceCounterpartySummary b) =>
              b.inMinor.compareTo(a.inMinor),
        );

    return FinanceSummary(
      period: period,
      inMinor: inMinor,
      outMinor: outMinor,
      count: business.length,
      inflowCount: business.where((Transaction row) => row.isInflow).length,
      previousInMinor: previousInMinor,
      previousOutMinor: previousOutMinor,
      previousCount: previousBusiness.length,
      buckets: buckets,
      methods: methods,
      topCounterparties: counterparties.take(5).toList(growable: false),
      currency: business.isNotEmpty ? business.first.currency : 'BDT',
      transactions: List<Transaction>.unmodifiable(business),
    );
  }

  final FinancePeriod period;
  final int inMinor;
  final int outMinor;
  final int count;
  final int inflowCount;
  final int previousInMinor;
  final int previousOutMinor;
  final int previousCount;
  final List<FinanceBucketSummary> buckets;
  final List<FinanceMethodSummary> methods;
  final List<FinanceCounterpartySummary> topCounterparties;
  final String currency;
  final List<Transaction> transactions;

  int get netMinor => inMinor - outMinor;

  bool get isEmpty => count == 0;

  bool get hasPrevious => previousCount > 0;

  /// Percentage change in money in versus the previous equal-length window.
  /// Null when there is no previous money to compare with.
  double? get inChangePercent {
    if (previousInMinor <= 0) return null;
    return (inMinor - previousInMinor) / previousInMinor * 100;
  }

  double? get outChangePercent {
    if (previousOutMinor <= 0) return null;
    return (outMinor - previousOutMinor) / previousOutMinor * 100;
  }

  int get averageInflowMinor => inflowCount == 0 ? 0 : inMinor ~/ inflowCount;

  FinanceBucketSummary? get busiestBucket {
    if (buckets.isEmpty) return null;
    final List<FinanceBucketSummary> ranked =
        List<FinanceBucketSummary>.of(buckets)..sort(
          (FinanceBucketSummary a, FinanceBucketSummary b) =>
              b.inMinor.compareTo(a.inMinor),
        );
    return ranked.first.isEmpty ? null : ranked.first;
  }

  FinanceMethodSummary? get topMethod {
    if (methods.isEmpty) return null;
    return methods.first;
  }
}

String effectivePaymentMethod(Transaction transaction) {
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

List<FinanceBucketSummary> _bucketSkeleton(FinancePeriod period) {
  final List<DateTime> starts = _bucketStarts(period);
  return <FinanceBucketSummary>[
    for (int index = 0; index < starts.length; index++)
      FinanceBucketSummary(
        start: starts[index],
        end: index + 1 < starts.length
            ? starts[index + 1].subtract(const Duration(milliseconds: 1))
            : period.end,
        label: _bucketLabel(period.bucket, starts[index]),
        inMinor: 0,
        outMinor: 0,
        count: 0,
      ),
  ];
}

List<FinanceBucketSummary> _buildBuckets(
  FinancePeriod period,
  List<Transaction> rows,
) {
  final List<DateTime> starts = _bucketStarts(period);
  if (starts.isEmpty) return const <FinanceBucketSummary>[];

  final Map<int, ({int inMinor, int outMinor, int count})> totals =
      <int, ({int inMinor, int outMinor, int count})>{};

  for (final Transaction row in rows) {
    final int index = _bucketIndex(period, starts, row.occurredAt);
    if (index < 0 || index >= starts.length) continue;

    final current = totals[index] ?? (inMinor: 0, outMinor: 0, count: 0);
    totals[index] = (
      inMinor: current.inMinor + (row.isInflow ? row.amountMinor : 0),
      outMinor: current.outMinor + (row.isInflow ? 0 : row.amountMinor),
      count: current.count + 1,
    );
  }

  return <FinanceBucketSummary>[
    for (int index = 0; index < starts.length; index++)
      FinanceBucketSummary(
        start: starts[index],
        end: index + 1 < starts.length
            ? starts[index + 1].subtract(const Duration(milliseconds: 1))
            : period.end,
        label: _bucketLabel(period.bucket, starts[index]),
        inMinor: totals[index]?.inMinor ?? 0,
        outMinor: totals[index]?.outMinor ?? 0,
        count: totals[index]?.count ?? 0,
      ),
  ];
}

List<DateTime> _bucketStarts(FinancePeriod period) {
  final List<DateTime> starts = <DateTime>[];
  DateTime cursor = switch (period.bucket) {
    FinanceBucket.month => DateTime(period.start.year, period.start.month),
    _ => DateTime(period.start.year, period.start.month, period.start.day),
  };

  while (!cursor.isAfter(period.end)) {
    starts.add(cursor);
    cursor = switch (period.bucket) {
      FinanceBucket.day => cursor.add(const Duration(days: 1)),
      FinanceBucket.week => cursor.add(const Duration(days: 7)),
      FinanceBucket.month => DateTime(cursor.year, cursor.month + 1),
    };
  }

  return starts;
}

int _bucketIndex(FinancePeriod period, List<DateTime> starts, DateTime when) {
  if (starts.isEmpty) return -1;

  return switch (period.bucket) {
    FinanceBucket.day => DateTime(
      when.year,
      when.month,
      when.day,
    ).difference(starts.first).inDays,
    FinanceBucket.week => when.difference(starts.first).inDays ~/ 7,
    FinanceBucket.month =>
      (when.year - starts.first.year) * 12 + (when.month - starts.first.month),
  };
}

String _bucketLabel(FinanceBucket bucket, DateTime start) => switch (bucket) {
  FinanceBucket.day => DateFormat('d MMM').format(start),
  FinanceBucket.week => DateFormat('d MMM').format(start),
  FinanceBucket.month => DateFormat('MMM').format(start),
};
