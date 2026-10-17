import '../core/api_client.dart';

/// One of the four rule-based inputs to the score.
class CreditFactor {
  const CreditFactor({
    required this.name,
    required this.score,
    required this.weight,
    required this.label,
  });

  factory CreditFactor.fromJson(Map<String, dynamic> json) => CreditFactor(
    name: json['name']?.toString() ?? '',
    score: asInt(json['score']),
    weight: asDouble(json['weight']),
    label: json['label']?.toString() ?? '',
  );

  /// consistency | volume | stability | activity
  final String name;

  /// 0-100.
  final int score;

  /// Contribution to the final score; the four weights sum to 1.
  final double weight;

  /// Plain-language explanation, shown under the factor bar.
  final String label;

  String get displayName => switch (name) {
    'consistency' => 'Consistency',
    'volume' => 'Sales volume',
    'stability' => 'Stability',
    'activity' => 'Activity',
    _ => name.isEmpty ? 'Factor' : name,
  };

  /// Points this factor contributes out of 100, rounded for display.
  int get contributionPoints => (score * weight).round();
}

/// The shop's derived credit signal.
///
/// This is a *behavioural* score computed from the shop's own recorded
/// transactions. It is not a credit bureau score and is not a lending decision.
class CreditProfile {
  const CreditProfile({
    required this.shopId,
    required this.score,
    required this.factors,
    required this.monthlyRevenueAvgMinor,
    required this.monthlyVolatility,
    required this.transactionCount90d,
    required this.riskFlags,
    this.computedAt,
  });

  factory CreditProfile.fromJson(Map<String, dynamic> json) => CreditProfile(
    shopId: json['shopId']?.toString() ?? '',
    score: asInt(json['score']),
    factors: asJsonList(
      json['factors'],
    ).map(CreditFactor.fromJson).toList(growable: false),
    monthlyRevenueAvgMinor: asInt(json['monthlyRevenueAvgMinor']),
    monthlyVolatility: asDouble(json['monthlyVolatility']),
    transactionCount90d: asInt(json['transactionCount90d']),
    riskFlags: (json['riskFlags'] is List)
        ? (json['riskFlags'] as List)
              .map((flag) => flag.toString())
              .toList(growable: false)
        : const <String>[],
    computedAt: asDateTime(json['computedAt']),
  );

  static const CreditProfile empty = CreditProfile(
    shopId: '',
    score: 0,
    factors: <CreditFactor>[],
    monthlyRevenueAvgMinor: 0,
    monthlyVolatility: 0,
    transactionCount90d: 0,
    riskFlags: <String>[],
  );

  final String shopId;

  /// 0-100.
  final int score;
  final List<CreditFactor> factors;
  final int monthlyRevenueAvgMinor;

  /// 0-1 coefficient of variation across monthly inflow.
  final double monthlyVolatility;
  final int transactionCount90d;
  final List<String> riskFlags;
  final DateTime? computedAt;

  /// Risk flags rendered as sentences. The raw codes are stable; the wording is
  /// what the owner should actually see.
  List<String> get riskExplanations => riskFlags
      .map(
        (flag) => switch (flag) {
          'no_activity' => 'No transactions recorded in the last 90 days yet.',
          'no_inflow' => 'No money coming in has been recorded yet.',
          'insufficient_history' =>
            'Fewer than 10 transactions so far — more history gives a steadier score.',
          'low_activity' =>
            'Sales are concentrated in a few days. Recording more days helps.',
          'high_volatility' =>
            'Monthly revenue swings a lot. Lenders prefer steadier months.',
          'revenue_declining' =>
            'Revenue is down more than 30% versus the previous month.',
          'counterparty_concentration' =>
            'Most revenue comes from one payer, which is a concentration risk.',
          _ => flag.replaceAll('_', ' '),
        },
      )
      .toList(growable: false);
}
