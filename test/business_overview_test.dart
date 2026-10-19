import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/theme.dart';
import 'package:greenbiz/features/finance/finance_controller.dart';
import 'package:greenbiz/features/finance/finance_insights.dart';
import 'package:greenbiz/features/finance/finance_period.dart';
import 'package:greenbiz/features/finance/widgets/business_overview_card.dart';
import 'package:greenbiz/models/transaction.dart';

class _FixedPeriodController extends FinancePeriodController {
  _FixedPeriodController(this.value);

  final FinancePeriod value;

  @override
  FinancePeriod build() => value;
}

Transaction _tx({
  required String id,
  required String direction,
  required int amountMinor,
  required DateTime occurredAt,
  required String method,
  required String counterparty,
}) => Transaction(
  id: id,
  shopId: 'shop',
  direction: direction,
  amountMinor: amountMinor,
  currency: 'BDT',
  occurredAt: occurredAt,
  paymentMethod: method,
  counterparty: counterparty,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('business overview renders totals, chart and insight lines', (
    WidgetTester tester,
  ) async {
    final FinancePeriod period = FinancePeriod.monthOf(DateTime(2026, 10));
    final FinanceSummary summary = FinanceSummary.build(
      period: period,
      rows: <Transaction>[
        _tx(
          id: '1',
          direction: 'in',
          amountMinor: 120000,
          occurredAt: DateTime(2026, 10, 1, 10),
          method: 'bkash',
          counterparty: 'Ayesha',
        ),
        _tx(
          id: '2',
          direction: 'out',
          amountMinor: 20000,
          occurredAt: DateTime(2026, 10, 2, 11),
          method: 'cash',
          counterparty: 'Supplier',
        ),
        _tx(
          id: '3',
          direction: 'in',
          amountMinor: 80000,
          occurredAt: DateTime(2026, 10, 3, 12),
          method: 'nagad',
          counterparty: 'Babul',
        ),
      ],
      previousRows: <Transaction>[
        _tx(
          id: 'p1',
          direction: 'in',
          amountMinor: 100000,
          occurredAt: DateTime(2026, 9, 12),
          method: 'bkash',
          counterparty: 'Ayesha',
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePeriodProvider.overrideWith(
            () => _FixedPeriodController(period),
          ),
          financeInsightsProvider(period).overrideWith((Ref ref) => summary),
        ],
        child: MaterialApp(
          theme: GreenBizTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: BusinessOverviewCard()),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Business overview'), findsOneWidget);
    // The figures and the chart legend both label the two flows.
    expect(find.text('Money in'), findsWidgets);
    expect(find.text('Money out'), findsWidgets);
    expect(find.text('Where the money came in'), findsOneWidget);
    expect(find.textContaining('Best day'), findsOneWidget);
    expect(find.text('Open full report'), findsOneWidget);
    expect(find.textContaining('Previous period:'), findsOneWidget);
  });

  testWidgets('the overview fits a narrow phone without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final FinancePeriod period = FinancePeriod.monthOf(DateTime(2026, 10));
    final FinanceSummary summary = FinanceSummary.build(
      period: period,
      rows: <Transaction>[
        _tx(
          id: '1',
          direction: 'in',
          amountMinor: 14850000,
          occurredAt: DateTime(2026, 10, 1, 10),
          method: 'bkash',
          counterparty: 'Ayesha Traders and General Store',
        ),
        _tx(
          id: '2',
          direction: 'out',
          amountMinor: 98765432,
          occurredAt: DateTime(2026, 10, 2, 11),
          method: 'cash',
          counterparty: 'Supplier',
        ),
      ],
      previousRows: <Transaction>[
        _tx(
          id: 'p1',
          direction: 'in',
          amountMinor: 10000000,
          occurredAt: DateTime(2026, 9, 12),
          method: 'bkash',
          counterparty: 'Ayesha',
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePeriodProvider.overrideWith(
            () => _FixedPeriodController(period),
          ),
          financeInsightsProvider(period).overrideWith((Ref ref) => summary),
        ],
        child: MaterialApp(
          theme: GreenBizTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: BusinessOverviewCard()),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // A RenderFlex overflow surfaces here as a thrown FlutterError.
    expect(tester.takeException(), isNull);
  });
}
