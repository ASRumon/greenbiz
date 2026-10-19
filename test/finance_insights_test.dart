import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/features/finance/finance_insights.dart';
import 'package:greenbiz/features/finance/finance_period.dart';
import 'package:greenbiz/models/transaction.dart';

Transaction _tx({
  required String id,
  required String direction,
  required int amountMinor,
  required DateTime occurredAt,
  String? method,
  String? counterparty,
  bool isBusiness = true,
  int subtotalMinor = 0,
  int discountMinor = 0,
}) {
  return Transaction(
    id: id,
    shopId: 'shop',
    direction: direction,
    amountMinor: amountMinor,
    currency: 'BDT',
    occurredAt: occurredAt,
    paymentMethod: method,
    counterparty: counterparty,
    isBusiness: isBusiness,
    subtotalMinor: subtotalMinor,
    discountMinor: discountMinor,
  );
}

void main() {
  group('finance periods', () {
    test('this month compares with an equal-length previous window', () {
      final FinancePeriod period = FinancePeriod.thisMonth(
        DateTime(2026, 10, 17, 12),
      );

      expect(period.start, DateTime(2026, 10, 1));
      expect(period.end, DateTime(2026, 10, 17, 12));
      expect(period.bucket, FinanceBucket.day);
      expect(period.previousEnd, DateTime(2026, 9, 30, 23, 59, 59, 999));
      expect(
        period.previousEnd.difference(period.previousStart),
        period.end.difference(period.start),
      );
    });

    test('last month is a whole calendar month', () {
      final FinancePeriod period = FinancePeriod.lastMonth(
        DateTime(2026, 10, 17),
      );

      expect(period.label, 'September 2026');
      expect(period.start, DateTime(2026, 9, 1));
      expect(period.end, DateTime(2026, 9, 30, 23, 59, 59, 999));
    });

    test('the year uses month buckets', () {
      final FinancePeriod period = FinancePeriod.thisYear(
        DateTime(2026, 10, 17),
      );

      expect(period.bucket, FinanceBucket.month);
      expect(period.start, DateTime(2026));
    });

    test('a picked month is stable across equal values', () {
      final FinancePeriod a = FinancePeriod.monthOf(DateTime(2026, 8, 1));
      final FinancePeriod b = FinancePeriod.monthOf(DateTime(2026, 8, 22));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('finance summary', () {
    final FinancePeriod period = FinancePeriod.monthOf(DateTime(2026, 10));

    final List<Transaction> rows = <Transaction>[
      _tx(
        id: '1',
        direction: 'in',
        amountMinor: 100000,
        occurredAt: DateTime(2026, 10, 1, 9),
        method: 'bkash',
        counterparty: 'Ayesha',
      ),
      _tx(
        id: '2',
        direction: 'out',
        amountMinor: 20000,
        occurredAt: DateTime(2026, 10, 2, 10),
        method: 'cash',
        counterparty: 'Supplier',
      ),
      _tx(
        id: '3',
        direction: 'in',
        amountMinor: 50000,
        occurredAt: DateTime(2026, 10, 17, 11),
        method: 'nagad',
        counterparty: 'Ayesha',
      ),
      _tx(
        id: '4',
        direction: 'in',
        amountMinor: 25000,
        occurredAt: DateTime(2026, 10, 17, 15),
        method: 'cash',
        counterparty: 'Babul',
        subtotalMinor: 25700,
        discountMinor: 700,
      ),
      _tx(
        id: '5',
        direction: 'in',
        amountMinor: 999000,
        occurredAt: DateTime(2026, 10, 10),
        method: 'bkash',
        counterparty: 'Personal',
        isBusiness: false,
      ),
    ];

    final List<Transaction> previous = <Transaction>[
      _tx(
        id: 'p1',
        direction: 'in',
        amountMinor: 60000,
        occurredAt: DateTime(2026, 9, 10),
        method: 'bkash',
      ),
      _tx(
        id: 'p2',
        direction: 'out',
        amountMinor: 30000,
        occurredAt: DateTime(2026, 9, 11),
        method: 'cash',
      ),
    ];

    final FinanceSummary summary = FinanceSummary.build(
      period: period,
      rows: rows,
      previousRows: previous,
    );

    test('totals exclude personal rows', () {
      expect(summary.inMinor, 175000);
      expect(summary.outMinor, 20000);
      expect(summary.netMinor, 155000);
      expect(summary.count, 4);
      expect(summary.inflowCount, 3);
    });

    test('builds one bucket per day of the month', () {
      expect(summary.buckets.length, 31);
      expect(summary.buckets.first.inMinor, 100000);
      expect(summary.buckets[16].inMinor, 75000);
      expect(summary.buckets[16].count, 2);
    });

    test('compares with the previous equal period', () {
      expect(summary.previousInMinor, 60000);
      expect(summary.previousOutMinor, 30000);
      expect(summary.inChangePercent, closeTo(191.67, 0.01));
      expect(summary.outChangePercent, closeTo(-33.33, 0.01));
    });

    test('ranks methods and payers', () {
      expect(summary.methods.first.method, 'bkash');
      expect(summary.methods.first.inMinor, 100000);
      expect(summary.topCounterparties.first.name, 'Ayesha');
      expect(summary.topCounterparties.first.inMinor, 150000);
      expect(summary.topCounterparties.length, 2);
    });

    test('names the busiest day and averages incoming sales', () {
      expect(summary.busiestBucket?.start, DateTime(2026, 10, 1));
      expect(summary.averageInflowMinor, 58333);
    });

    test('sums the discounts given, in Taka', () {
      expect(summary.discountMinor, 700);
      expect(summary.hasDiscount, isTrue);
    });

    test('an empty period still has chart buckets', () {
      final FinanceSummary empty = FinanceSummary.empty(period);

      expect(empty.isEmpty, isTrue);
      expect(empty.buckets.length, 31);
      expect(empty.inChangePercent, isNull);
    });
  });
}
