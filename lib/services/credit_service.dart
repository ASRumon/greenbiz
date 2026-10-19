import '../core/api_client.dart';
import '../models/credit_profile.dart';
import '../models/plan.dart';

/// How comfortably the shop's revenue covers a plan's instalment.
///
/// The server uses the owner's rule: revenue at least twice the instalment is
/// high priority, 1.3× or more is possible, anything less is a stretch.
enum MatchPriority {
  high('High priority'),
  medium('Good fit'),
  low('Stretch'),
  unknown('Terms on request');

  const MatchPriority(this.label);

  final String label;

  static MatchPriority parse(String? raw) => switch (raw) {
    'high' => MatchPriority.high,
    'medium' => MatchPriority.medium,
    'low' => MatchPriority.low,
    _ => MatchPriority.unknown,
  };
}

/// A matched plan, as returned by `GET /shops/:id/matched-plans`.
class PlanMatch {
  const PlanMatch({
    required this.plan,
    required this.fitScore,
    required this.priority,
    required this.reasons,
    this.emiMinor,
    this.suggestedAmountMinor,
    this.affordabilityRatio,
    this.interestRatePct,
    this.tenorMonths,
    this.facility = 'term',
    this.requirements = const <String>[],
    this.warnings = const <String>[],
  });

  final Plan plan;
  final double fitScore;
  final MatchPriority priority;
  final List<String> reasons;

  /// Estimated monthly repayment. Null when the product publishes no rate.
  final int? emiMinor;

  /// Principal the shop's revenue can comfortably service on this product.
  final int? suggestedAmountMinor;

  /// monthlyRevenue / emiMinor.
  final double? affordabilityRatio;
  final double? interestRatePct;
  final int? tenorMonths;

  /// term | revolving | interest_only | bullet
  final String facility;

  final List<String> requirements;
  final List<String> warnings;

  bool get isInterestOnly =>
      facility == 'revolving' || facility == 'interest_only';

  /// The matcher returns `institutionName` and `institutionType` as siblings of
  /// `plan`, not inside it. Fold them into the plan map so every caller can
  /// name the bank from `plan.institutionName` (before this, matched tiles
  /// rendered "Unknown provider" for every lender).
  factory PlanMatch.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> planJson = json['plan'] is Map
        ? Map<String, dynamic>.from(json['plan'] as Map)
        : Map<String, dynamic>.from(json);

    return PlanMatch(
      plan: Plan.fromJson(<String, dynamic>{
        ...planJson,
        'institutionName':
            planJson['institutionName'] ?? json['institutionName'],
        'institutionType':
            planJson['institutionType'] ?? json['institutionType'],
      }),
      fitScore: asDouble(json['fitScore']),
      priority: MatchPriority.parse(asString(json['priority'])),
      reasons: _asStrings(json['reasons']),
      emiMinor: json['emiMinor'] == null ? null : asInt(json['emiMinor']),
      suggestedAmountMinor: json['suggestedAmountMinor'] == null
          ? null
          : asInt(json['suggestedAmountMinor']),
      affordabilityRatio: json['affordabilityRatio'] == null
          ? null
          : asDouble(json['affordabilityRatio']),
      interestRatePct: json['interestRatePct'] == null
          ? null
          : asDouble(json['interestRatePct']),
      tenorMonths: json['tenorMonths'] == null
          ? null
          : asInt(json['tenorMonths']),
      facility: asString(json['facility']) ?? 'term',
      requirements: _asStrings(json['requirements']),
      warnings: _asStrings(json['warnings']),
    );
  }
}

/// The server's "how much can I borrow?" estimate.
///
/// The instalment is capped at half of average monthly business revenue, which
/// is exactly the 2× cover that makes a plan high priority.
class LoanCapacity {
  const LoanCapacity({
    required this.monthlyRevenueMinor,
    required this.maxAffordableEmiMinor,
    required this.suggestedAmountMinor,
    required this.tenorMonths,
    required this.interestRatePct,
    required this.priority,
    required this.basis,
    required this.assumptions,
    this.facility = 'term',
    this.affordabilityRatio,
  });

  final int monthlyRevenueMinor;
  final int maxAffordableEmiMinor;
  final int suggestedAmountMinor;
  final int tenorMonths;
  final double interestRatePct;
  final String facility;
  final double? affordabilityRatio;
  final MatchPriority priority;

  /// matched_plan | indicative_benchmark | insufficient_revenue
  final String basis;
  final List<String> assumptions;

  bool get hasSuggestion => suggestedAmountMinor > 0;
  bool get isInsufficientRevenue => basis == 'insufficient_revenue';

  factory LoanCapacity.fromJson(Map<String, dynamic> json) => LoanCapacity(
    monthlyRevenueMinor: asInt(json['monthlyRevenueMinor']),
    maxAffordableEmiMinor: asInt(json['maxAffordableEmiMinor']),
    suggestedAmountMinor: asInt(json['suggestedAmountMinor']),
    tenorMonths: asInt(json['tenorMonths']),
    interestRatePct: asDouble(json['interestRatePct']),
    facility: asString(json['facility']) ?? 'term',
    affordabilityRatio: json['affordabilityRatio'] == null
        ? null
        : asDouble(json['affordabilityRatio']),
    priority: MatchPriority.parse(asString(json['priority'])),
    basis: asString(json['basis']) ?? 'indicative_benchmark',
    assumptions: _asStrings(json['assumptions']),
  );
}

class MatchResult {
  const MatchResult({
    required this.matches,
    required this.message,
    this.capacity,
  });

  factory MatchResult.fromJson(Map<String, dynamic> json) => MatchResult(
    matches: asJsonList(json['matches'])
        .map(PlanMatch.fromJson)
        .toList(growable: false),
    capacity: json['capacity'] is Map
        ? LoanCapacity.fromJson(
            Map<String, dynamic>.from(json['capacity'] as Map),
          )
        : null,
    message:
        asString(json['message']) ??
        'Record your business sales to see plans matched to your revenue.',
  );

  static const MatchResult empty = MatchResult(
    matches: <PlanMatch>[],
    message: 'Connect once to download plans matched to your recorded revenue.',
  );

  final List<PlanMatch> matches;
  final LoanCapacity? capacity;

  /// The server's explanation for an empty list. Rendered verbatim so the app
  /// does not have to hard-code the same sentence in two places.
  final String message;

  bool get isEmpty => matches.isEmpty;
}

List<String> _asStrings(dynamic value) {
  if (value is! List) return const <String>[];
  return value.map((entry) => entry.toString()).toList(growable: false);
}

class CreditService {
  CreditService(this._api);

  final ApiClient _api;

  Future<CreditProfile> get(String shopId) async {
    final json = await _api.get('/shops/$shopId/credit');
    return CreditProfile.fromJson(_asMap(json['creditProfile']));
  }

  Future<CreditProfile> recompute(String shopId) async {
    final json = await _api.post('/shops/$shopId/credit/recompute');
    return CreditProfile.fromJson(_asMap(json['creditProfile']));
  }

  /// Fetches plans ranked against the shop's recorded revenue.
  Future<MatchResult> matchedPlans(
    String shopId, {
    String intent = 'loan',
    int? amountMinor,
  }) async {
    final json = await _api.get(
      '/shops/$shopId/matched-plans',
      query: <String, dynamic>{'intent': intent, 'amountMinor': ?amountMinor},
    );

    return MatchResult.fromJson(json);
  }

  /// The public plan directory. No shop data, no secrets.
  Future<List<Plan>> directory({String? serviceType}) async {
    final json = await _api.get(
      '/plans',
      query: <String, dynamic>{'limit': 100, 'serviceType': ?serviceType},
    );
    return asJsonList(json['plans']).map(Plan.fromJson).toList(growable: false);
  }

  Future<List<Institution>> institutions() async {
    final json = await _api.get('/institutions');
    return asJsonList(json['institutions'])
        .map(Institution.fromJson)
        .toList(growable: false);
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
