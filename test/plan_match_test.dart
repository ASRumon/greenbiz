import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/services/credit_service.dart';

/// The Finance card renders exactly what these parsers produce, so the wire
/// shape is pinned here: a new field or a renamed priority must fail a test.
void main() {
  group('PlanMatch', () {
    test('parses a high-priority ranked plan', () {
      final PlanMatch match = PlanMatch.fromJson(<String, dynamic>{
        'plan': <String, dynamic>{
          'id': 'p1',
          'institutionId': 'i1',
          'planName': 'Startup Builder',
          'serviceType': 'loan',
          'interestRateMin': 4.0,
          'durationMonths': 60,
        },
        // The matcher puts the lender beside the plan, not inside it.
        'institutionName': 'BRAC Bank',
        'institutionType': 'commercial_bank',
        'fitScore': 0.91,
        'priority': 'high',
        'emiMinor': 1017254,
        'suggestedAmountMinor': 55200000,
        'affordabilityRatio': 2.0,
        'interestRatePct': 4.0,
        'tenorMonths': 60,
        'facility': 'term',
        'reasons': <String>['Instalment about ৳10,172/month.'],
        'requirements': <String>['Valid trade licence'],
        'warnings': <String>[],
      });

      expect(match.priority, MatchPriority.high);
      expect(match.priority.label, 'High priority');
      expect(match.emiMinor, 1017254);
      expect(match.suggestedAmountMinor, 55200000);
      expect(match.affordabilityRatio, 2.0);
      expect(match.isInterestOnly, isFalse);
      expect(match.plan.planName, 'Startup Builder');
      expect(match.plan.institutionName, 'BRAC Bank');
      expect(match.plan.institutionType, 'commercial_bank');
      expect(match.reasons, hasLength(1));
      expect(match.requirements, <String>['Valid trade licence']);
    });

    test(
      'never loses the lender name, which used to render Unknown provider',
      () {
        final PlanMatch match = PlanMatch.fromJson(<String, dynamic>{
          'plan': <String, dynamic>{
            'id': 'p3',
            'institutionId': '11111111-1111-4111-8111-000000000004',
            'planName': 'DBBL Unnoyan (SMEDP-2 Term Loan)',
            'serviceType': 'loan',
          },
          'institutionName': 'Dutch-Bangla Bank (DBBL)',
          'institutionType': 'commercial_bank',
          'fitScore': 0.62,
          'priority': 'medium',
          'reasons': <String>[],
        });

        expect(match.plan.institutionName, 'Dutch-Bangla Bank (DBBL)');
      },
    );

    test('marks a revolving facility as interest-only', () {
      final PlanMatch match = PlanMatch.fromJson(<String, dynamic>{
        'plan': <String, dynamic>{
          'id': 'p2',
          'institutionId': 'i1',
          'planName': 'Cash Credit',
          'serviceType': 'working_capital',
        },
        'fitScore': 0.7,
        'priority': 'medium',
        'facility': 'revolving',
        'emiMinor': 600979,
      });

      expect(match.isInterestOnly, isTrue);
      expect(match.suggestedAmountMinor, isNull);
    });

    test('treats an unknown priority as terms on request', () {
      expect(MatchPriority.parse('some-new-band'), MatchPriority.unknown);
      expect(MatchPriority.parse(null), MatchPriority.unknown);
    });
  });

  group('LoanCapacity', () {
    test('parses the server estimate', () {
      final LoanCapacity capacity = LoanCapacity.fromJson(<String, dynamic>{
        'monthlyRevenueMinor': 2034508,
        'maxAffordableEmiMinor': 1017254,
        'suggestedAmountMinor': 55200000,
        'tenorMonths': 60,
        'interestRatePct': 4.0,
        'facility': 'term',
        'affordabilityRatio': 2.0,
        'priority': 'high',
        'basis': 'matched_plan',
        'assumptions': <String>['Instalment is capped at half of revenue.'],
      });

      expect(capacity.hasSuggestion, isTrue);
      expect(capacity.isInsufficientRevenue, isFalse);
      expect(capacity.monthlyRevenueMinor, 2034508);
      expect(capacity.maxAffordableEmiMinor, 1017254);
      expect(capacity.suggestedAmountMinor, 55200000);
      expect(capacity.tenorMonths, 60);
      expect(capacity.interestRatePct, 4.0);
      expect(capacity.priority, MatchPriority.high);
      expect(capacity.basis, 'matched_plan');
    });

    test('renders the no-revenue state without a suggestion', () {
      final LoanCapacity capacity = LoanCapacity.fromJson(<String, dynamic>{
        'monthlyRevenueMinor': 0,
        'maxAffordableEmiMinor': 0,
        'suggestedAmountMinor': 0,
        'tenorMonths': 0,
        'interestRatePct': 0,
        'priority': 'unknown',
        'basis': 'insufficient_revenue',
        'assumptions': <String>['Record business sales for at least a month.'],
      });

      expect(capacity.hasSuggestion, isFalse);
      expect(capacity.isInsufficientRevenue, isTrue);
    });
  });

  test('MatchResult carries capacity alongside the matches', () {
    final MatchResult result = MatchResult.fromJson(<String, dynamic>{
      'matches': <dynamic>[],
      'capacity': <String, dynamic>{
        'monthlyRevenueMinor': 0,
        'maxAffordableEmiMinor': 0,
        'suggestedAmountMinor': 0,
        'tenorMonths': 0,
        'interestRatePct': 0,
        'priority': 'unknown',
        'basis': 'insufficient_revenue',
        'assumptions': <String>[],
      },
      'message': 'Record more sales.',
    });

    expect(result.isEmpty, isTrue);
    expect(result.capacity, isNotNull);
    expect(result.message, 'Record more sales.');
  });
}
