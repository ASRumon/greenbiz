import 'package:intl/intl.dart';

/// The preset ranges offered in the Finance tab.
enum FinancePreset { thisWeek, thisMonth, lastMonth, last90Days, thisYear }

/// How a range is split into chart bars.
enum FinanceBucket { day, week, month }

/// A calendar range plus the equal-length range immediately before it.
///
/// The previous window is deliberately the same length as the current one, not
/// the previous calendar month, so "this month so far" is never compared with a
/// full 30-day month. That would make a normal partial month look like a slump.
class FinancePeriod {
  const FinancePeriod({
    required this.preset,
    required this.start,
    required this.end,
    required this.previousStart,
    required this.previousEnd,
    required this.bucket,
    required this.label,
  });

  final FinancePreset? preset;

  /// Inclusive.
  final DateTime start;

  /// Inclusive.
  final DateTime end;

  /// Inclusive.
  final DateTime previousStart;

  /// Inclusive.
  final DateTime previousEnd;

  final FinanceBucket bucket;
  final String label;

  DateTime get previousEndExclusive =>
      previousEnd.add(const Duration(milliseconds: 1));

  factory FinancePeriod.thisWeek([DateTime? now]) {
    final DateTime reference = now ?? DateTime.now();
    final DateTime today = DateTime(
      reference.year,
      reference.month,
      reference.day,
    );
    final DateTime monday = today.subtract(
      Duration(days: today.weekday - DateTime.monday),
    );
    final DateTime end = reference;
    final Duration length = end.difference(monday);
    final DateTime previousEnd = monday.subtract(
      const Duration(milliseconds: 1),
    );

    return FinancePeriod(
      preset: FinancePreset.thisWeek,
      start: monday,
      end: end,
      previousStart: previousEnd.subtract(length),
      previousEnd: previousEnd,
      bucket: FinanceBucket.day,
      label: 'This week',
    );
  }

  factory FinancePeriod.thisMonth([DateTime? now]) {
    final DateTime reference = now ?? DateTime.now();
    final DateTime start = DateTime(reference.year, reference.month);
    final DateTime previousEnd = start.subtract(
      const Duration(milliseconds: 1),
    );
    final Duration length = reference.difference(start);

    return FinancePeriod(
      preset: FinancePreset.thisMonth,
      start: start,
      end: reference,
      previousStart: previousEnd.subtract(length),
      previousEnd: previousEnd,
      bucket: FinanceBucket.day,
      label: 'This month',
    );
  }

  factory FinancePeriod.lastMonth([DateTime? now]) {
    final DateTime reference = now ?? DateTime.now();
    final DateTime start = DateTime(reference.year, reference.month - 1);
    final DateTime end = DateTime(
      reference.year,
      reference.month,
      0,
      23,
      59,
      59,
      999,
    );
    final DateTime previousStart = DateTime(
      reference.year,
      reference.month - 2,
    );
    final DateTime previousEnd = start.subtract(
      const Duration(milliseconds: 1),
    );

    return FinancePeriod(
      preset: FinancePreset.lastMonth,
      start: start,
      end: end,
      previousStart: previousStart,
      previousEnd: previousEnd,
      bucket: FinanceBucket.day,
      label: DateFormat('MMMM yyyy').format(start),
    );
  }

  factory FinancePeriod.last90Days([DateTime? now]) {
    final DateTime reference = now ?? DateTime.now();
    final DateTime end = reference;
    final DateTime start = DateTime(
      reference.year,
      reference.month,
      reference.day,
    ).subtract(const Duration(days: 89));
    final Duration length = end.difference(start);
    final DateTime previousEnd = start.subtract(
      const Duration(milliseconds: 1),
    );

    return FinancePeriod(
      preset: FinancePreset.last90Days,
      start: start,
      end: end,
      previousStart: previousEnd.subtract(length),
      previousEnd: previousEnd,
      bucket: FinanceBucket.week,
      label: 'Last 90 days',
    );
  }

  factory FinancePeriod.thisYear([DateTime? now]) {
    final DateTime reference = now ?? DateTime.now();
    final DateTime start = DateTime(reference.year);
    final DateTime previousEnd = start.subtract(
      const Duration(milliseconds: 1),
    );
    final Duration length = reference.difference(start);

    return FinancePeriod(
      preset: FinancePreset.thisYear,
      start: start,
      end: reference,
      previousStart: previousEnd.subtract(length),
      previousEnd: previousEnd,
      bucket: FinanceBucket.month,
      label: '${reference.year} so far',
    );
  }

  /// A whole calendar month, used by the month picker.
  factory FinancePeriod.monthOf(DateTime month) {
    final DateTime start = DateTime(month.year, month.month);
    final DateTime end = DateTime(
      month.year,
      month.month + 1,
      0,
      23,
      59,
      59,
      999,
    );
    final DateTime previousStart = DateTime(month.year, month.month - 1);
    final DateTime previousEnd = start.subtract(
      const Duration(milliseconds: 1),
    );

    return FinancePeriod(
      preset: null,
      start: start,
      end: end,
      previousStart: previousStart,
      previousEnd: previousEnd,
      bucket: FinanceBucket.day,
      label: DateFormat('MMMM yyyy').format(start),
    );
  }

  bool get isCustomMonth => preset == null;

  @override
  bool operator ==(Object other) =>
      other is FinancePeriod &&
      other.start == start &&
      other.end == end &&
      other.previousStart == previousStart &&
      other.previousEnd == previousEnd &&
      other.bucket == bucket;

  @override
  int get hashCode =>
      Object.hash(start, end, previousStart, previousEnd, bucket);
}
