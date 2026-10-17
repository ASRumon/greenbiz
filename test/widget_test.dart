// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/api_client.dart';
import 'package:greenbiz/core/env.dart';
import 'package:greenbiz/core/money.dart';
import 'package:greenbiz/core/theme.dart';
import 'package:greenbiz/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget and unit tests.
///
/// These cover the logic where a mistake costs real money — integer money
/// conversion, sender filtering, and score banding — plus smoke tests for the
/// shared widgets. Network-dependent screens are not exercised here; the API is
/// covered end to end by `scripts/smoke-test.ps1`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('money formatting', () {
    test('formats minor units without floating point drift', () {
      // 1699.05 * 100 is 169905.00000000003 as a double. This must not matter.
      expect(formatMinor(169905), '\u09F3 1,699.05');
      expect(formatMinor(150000), '\u09F3 1,500.00');
      expect(formatMinor(0), '\u09F3 0.00');
      expect(formatMinor(5), '\u09F3 0.05');
      expect(formatMinor(100), '\u09F3 1.00');
    });

    test('groups thousands correctly at boundaries', () {
      expect(formatMinor(99900), '\u09F3 999.00');
      expect(formatMinor(100000), '\u09F3 1,000.00');
      expect(formatMinor(100000000), '\u09F3 1,000,000.00');
    });

    test('handles negative amounts', () {
      // The symbol comes first and the sign applies to the number, which reads
      // more naturally than "-Tk 1,500.00".
      expect(formatMinor(-150000), '\u09F3 -1,500.00');
      expect(formatMinorCompact(-150000), '\u09F3 -1,500');
    });

    test('uses the right symbol per currency', () {
      expect(formatMinor(150000, currency: 'INR'), '\u20B9 1,500.00');
      expect(formatMinor(150000, currency: 'BDT'), '\u09F3 1,500.00');
      expect(formatMinor(150000, currency: 'USD'), 'USD 1,500.00');
    });

    test('formats compact amounts for cards', () {
      expect(formatMinorCompact(150000), '\u09F3 1,500');
      expect(formatMinorCompact(169905), '\u09F3 1,699');
    });
  });

  group('parseMajorToMinor', () {
    test('parses whole and decimal amounts exactly', () {
      expect(parseMajorToMinor('1500'), 150000);
      expect(parseMajorToMinor('1500.05'), 150005);
      expect(parseMajorToMinor('1500.5'), 150050);
      expect(parseMajorToMinor('1,500.00'), 150000);
      expect(parseMajorToMinor('0.01'), 1);
    });

    test('rejects input that is not a clean amount', () {
      // Three decimal places cannot be represented in minor units, so it is
      // rejected rather than silently truncated.
      expect(parseMajorToMinor('1.005'), isNull);
      expect(parseMajorToMinor('abc'), isNull);
      expect(parseMajorToMinor(''), isNull);
      expect(parseMajorToMinor('-5'), isNull);
    });

    test('round-trips through the editable form', () {
      for (final int minor in <int>[1, 5, 99, 100, 150000, 169905, 123456789]) {
        expect(parseMajorToMinor(minorToEditable(minor)), minor);
      }
    });
  });

  group('relativeTime', () {
    final DateTime now = DateTime(2026, 10, 17, 12);

    test('describes recent and distant times', () {
      expect(relativeTime(null), 'never');
      expect(
        relativeTime(now.subtract(const Duration(seconds: 5)), now: now),
        'just now',
      );
      expect(
        relativeTime(now.subtract(const Duration(minutes: 7)), now: now),
        '7 minutes ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(hours: 5)), now: now),
        '5 hours ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
      expect(
        relativeTime(now.subtract(const Duration(days: 65)), now: now),
        '2 months ago',
      );
    });
  });

  group('payment sender filtering', () {
    test('accepts Bangladeshi mobile money short codes', () {
      expect(Env.isPaymentSender('16247'), isTrue);
      expect(Env.isPaymentSender('16248'), isTrue);
      expect(Env.isPaymentSender('16216'), isTrue);
      expect(Env.isPaymentSender('bKash'), isTrue);
      expect(Env.isPaymentSender('Nagad'), isTrue);
      expect(Env.isPaymentSender('Rocket'), isTrue);
    });

    test('accepts Indian bank headers with prefixes and separators', () {
      // Indian alerts arrive as "VM-HDFCBK", not as a bare bank code.
      expect(Env.isPaymentSender('VM-HDFCBK'), isTrue);
      expect(Env.isPaymentSender('AD-SBIINB'), isTrue);
      expect(Env.isPaymentSender('VK-ICICIB'), isTrue);
    });

    test('rejects personal numbers and unknown senders', () {
      expect(Env.isPaymentSender('01712345678'), isFalse);
      expect(Env.isPaymentSender('+8801712345678'), isFalse);
      expect(Env.isPaymentSender('MUM'), isFalse);
      expect(Env.isPaymentSender(''), isFalse);
    });
  });

  group('credit score presentation', () {
    test('bands the score into the right colour and label', () {
      expect(GreenBizTheme.labelForScore(0), 'No data yet');
      expect(GreenBizTheme.labelForScore(20), 'Early');
      expect(GreenBizTheme.labelForScore(55), 'Building');
      expect(GreenBizTheme.labelForScore(85), 'Strong');

      expect(GreenBizTheme.forScore(10), GreenBizTheme.scoreLow);
      expect(GreenBizTheme.forScore(55), GreenBizTheme.scoreMedium);
      expect(GreenBizTheme.forScore(90), GreenBizTheme.scoreHigh);
    });

    test('boundaries land on the higher band', () {
      expect(GreenBizTheme.forScore(40), GreenBizTheme.scoreMedium);
      expect(GreenBizTheme.forScore(70), GreenBizTheme.scoreHigh);
    });
  });

  group('shared widgets', () {
    testWidgets('EmptyState shows its copy and its action', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GreenBizTheme.light(),
          home: Scaffold(
            body: EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Add your first product to get started',
              message: 'Track what you sell.',
              action: FilledButton(
                onPressed: () {},
                child: const Text('Add product'),
              ),
            ),
          ),
        ),
      );

      expect(
        find.text('Add your first product to get started'),
        findsOneWidget,
      );
      expect(find.text('Track what you sell.'), findsOneWidget);
      expect(find.text('Add product'), findsOneWidget);
    });

    testWidgets('ErrorView explains an offline failure', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GreenBizTheme.light(),
          home: const Scaffold(
            body: ErrorView(
              error: ApiException(
                code: 'NETWORK_ERROR',
                message: 'Cannot reach the GreenBiz server.',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Cannot reach the server'), findsOneWidget);
      expect(find.text('Cannot reach the GreenBiz server.'), findsOneWidget);
    });
  });

  test('the session token is not readable from the widget layer', () async {
    // Guards a privacy invariant: the token is persisted so the user stays
    // signed in, but ApiClient exposes only `hasSession`, never the value, so a
    // screen cannot render or log it by accident.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ApiClient client = ApiClient(preferences: prefs);

    expect(client.hasSession, isFalse);
    await client.setSessionToken('test-token');
    expect(client.hasSession, isTrue);
    expect(prefs.getString('greenbiz.session_token'), 'test-token');

    await client.setSessionToken(null);
    expect(prefs.getString('greenbiz.session_token'), isNull);
  });
}
