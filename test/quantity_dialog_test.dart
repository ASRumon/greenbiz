import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/features/sell/quantity_dialog.dart';
import 'package:greenbiz/models/product.dart';

Product _onion({int priceMinor = 6000, double stock = 10}) => Product(
  id: 'p-onion',
  shopId: 'shop-1',
  productName: 'Onion',
  unit: 'kg',
  unitPriceMinor: priceMinor,
  stockQuantity: stock,
);

/// Opens [QuantityDialog] and returns a getter for the value it popped with.
Future<double? Function()> _open(
  WidgetTester tester,
  QuantityDialog dialog,
) async {
  double? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showDialog<double>(
                  context: context,
                  builder: (_) => dialog,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

FilledButton _setButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set'));

void main() {
  testWidgets('typing an amount enables Set (the reported bug)', (
    WidgetTester tester,
  ) async {
    final double? Function() result = await _open(
      tester,
      QuantityDialog(
        product: _onion(),
        // No quantity yet means the money field starts empty. Before the fix
        // the dialog never rebuilt, so Set stayed disabled after typing.
        initialQuantity: 0,
        startWithAmount: true,
      ),
    );

    expect(find.text('Amount the customer is paying'), findsOneWidget);
    expect(_setButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();

    expect(find.textContaining('0.167 kg'), findsOneWidget);
    expect(_setButton(tester).onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(result(), closeTo(1000 / 6000, 1e-6));
  });

  testWidgets('switching to Amount prefills what the line currently costs', (
    WidgetTester tester,
  ) async {
    final double? Function() result = await _open(
      tester,
      QuantityDialog(product: _onion(), initialQuantity: 1),
    );

    expect(find.text('Quantity in kg'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('Amount'));
    await tester.pumpAndSettle();

    // One kg at ৳60 -> the amount field starts at 60, selected so typing
    // replaces it rather than appending to it.
    expect(find.text('60'), findsOneWidget);
    final TextField amountField = tester.widget<TextField>(
      find.byType(TextField),
    );
    expect(amountField.controller!.text, '60');
    expect(
      amountField.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    expect(_setButton(tester).onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    expect(result(), closeTo(1000 / 6000, 1e-6));
  });

  testWidgets('an amount above the stock value keeps Set disabled', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      QuantityDialog(
        product: _onion(stock: 0.1), // at most ৳6.00 of onion
        initialQuantity: 0,
        startWithAmount: true,
      ),
    );

    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();

    expect(find.textContaining('Only 0.10 kg in stock'), findsOneWidget);
    expect(_setButton(tester).onPressed, isNull);
  });

  testWidgets('a small budget for a calculator keeps one whole piece', (
    WidgetTester tester,
  ) async {
    final double? Function() result = await _open(
      tester,
      QuantityDialog(
        product: const Product(
          id: 'p-calc',
          shopId: 'shop-1',
          productName: 'Calculator',
          unit: 'piece',
          unitPriceMinor: 80000,
          stockQuantity: 5,
        ),
        initialQuantity: 1,
        startWithAmount: true,
      ),
    );

    await tester.enterText(find.byType(TextField), '70');
    await tester.pump();

    expect(find.textContaining('sold per piece'), findsOneWidget);
    expect(find.textContaining('1 piece'), findsWidgets);
    expect(_setButton(tester).onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();

    // One whole calculator, never 0.0875 of one.
    expect(result(), 1);
  });

  testWidgets('a packet budget buys whole packets and shows the change', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      QuantityDialog(
        product: const Product(
          id: 'p-chips',
          shopId: 'shop-1',
          productName: 'Chips',
          unit: 'packet',
          unitPriceMinor: 2000,
          stockQuantity: 10,
        ),
        initialQuantity: 1,
        startWithAmount: true,
      ),
    );

    await tester.enterText(find.byType(TextField), '70');
    await tester.pump();

    expect(find.textContaining('3 packet'), findsWidgets);
    expect(find.textContaining('left over'), findsOneWidget);
  });
}
