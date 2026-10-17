import '../core/api_client.dart';

/// A financial product from the public directory.
///
/// Read-only in the app: plans come from the seeded catalogue, not from user
/// input. The server ranks these against the shop's recorded revenue; the
/// ranking is an affordability estimate, not a lender approval.
class Plan {
  const Plan({
    required this.id,
    required this.institutionId,
    required this.planName,
    required this.serviceType,
    this.description,
    this.minAmountMinor,
    this.maxAmountMinor,
    this.interestRateMin,
    this.interestRateMax,
    this.durationMonths,
    this.eligibility,
    this.fees,
    this.sourceUrl,
    this.lastVerifiedAt,
    this.isActive = true,
    this.institutionName,
    this.institutionType,
  });

  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
    id: json['id']?.toString() ?? '',
    institutionId: json['institutionId']?.toString() ?? '',
    planName: json['planName']?.toString() ?? '',
    serviceType: json['serviceType']?.toString() ?? 'loan',
    description: asString(json['description']),
    minAmountMinor: json['minAmountMinor'] == null
        ? null
        : asInt(json['minAmountMinor']),
    maxAmountMinor: json['maxAmountMinor'] == null
        ? null
        : asInt(json['maxAmountMinor']),
    interestRateMin: json['interestRateMin'] == null
        ? null
        : asDouble(json['interestRateMin']),
    interestRateMax: json['interestRateMax'] == null
        ? null
        : asDouble(json['interestRateMax']),
    durationMonths: json['durationMonths'] == null
        ? null
        : asInt(json['durationMonths']),
    eligibility: json['eligibility'] is Map
        ? Map<String, dynamic>.from(json['eligibility'] as Map)
        : null,
    fees: json['fees'] is Map
        ? Map<String, dynamic>.from(json['fees'] as Map)
        : null,
    sourceUrl: asString(json['sourceUrl']),
    lastVerifiedAt: asDateTime(json['lastVerifiedAt']),
    isActive: json['isActive'] is bool ? json['isActive'] as bool : true,
    institutionName: asString(json['institutionName']),
    institutionType: asString(json['institutionType']),
  );

  final String id;
  final String institutionId;
  final String planName;

  /// loan | insurance | savings | current_account | working_capital
  final String serviceType;
  final String? description;
  final int? minAmountMinor;
  final int? maxAmountMinor;

  /// Percentage per annum. Null for insurance and deposit products.
  final double? interestRateMin;
  final double? interestRateMax;
  final int? durationMonths;
  final Map<String, dynamic>? eligibility;
  final Map<String, dynamic>? fees;
  final String? sourceUrl;

  /// Null means the catalogue entry has not been checked against the provider's
  /// current published terms. The UI says so rather than implying it is current.
  final DateTime? lastVerifiedAt;
  final bool isActive;

  /// Denormalised from the join, so a list renders without a second request.
  final String? institutionName;
  final String? institutionType;

  bool get isLoan => serviceType == 'loan' || serviceType == 'working_capital';
  bool get isInsurance => serviceType == 'insurance';

  bool get isVerified => lastVerifiedAt != null;

  String get typeLabel => switch (serviceType) {
    'loan' => 'Loan',
    'working_capital' => 'Working capital',
    'insurance' => 'Insurance',
    'savings' => 'Savings',
    'current_account' => 'Current account',
    _ => serviceType.replaceAll('_', ' '),
  };

  String? get interestLabel {
    if (interestRateMin == null && interestRateMax == null) return null;
    if (interestRateMin != null && interestRateMax != null) {
      if ((interestRateMin! - interestRateMax!).abs() < 0.01) {
        return '${interestRateMin!.toStringAsFixed(1)}% p.a.';
      }
      return '${interestRateMin!.toStringAsFixed(1)}–${interestRateMax!.toStringAsFixed(1)}% p.a.';
    }
    final single = interestRateMin ?? interestRateMax;
    return '${single!.toStringAsFixed(1)}% p.a.';
  }

  String? get durationLabel {
    if (durationMonths == null) return null;
    if (durationMonths! < 24) return '$durationMonths months';
    final years = durationMonths! / 12;
    final rounded = years.round();
    return years == rounded
        ? '$rounded years'
        : '${years.toStringAsFixed(1)} years';
  }
}

/// A lender, insurer, or scheme operator from the public directory.
class Institution {
  const Institution({
    required this.id,
    required this.name,
    required this.institutionType,
    this.website,
    this.description,
    this.activePlanCount = 0,
  });

  factory Institution.fromJson(Map<String, dynamic> json) => Institution(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    institutionType: json['institutionType']?.toString() ?? 'commercial_bank',
    website: asString(json['website']),
    description: asString(json['description']),
    activePlanCount: asInt(json['activePlanCount']),
  );

  final String id;
  final String name;
  final String institutionType;
  final String? website;
  final String? description;
  final int activePlanCount;

  String get typeLabel => switch (institutionType) {
    'commercial_bank' => 'Commercial bank',
    'nbfi' => 'Non-bank financial institution',
    'mfi' => 'Microfinance institution',
    'mfs' => 'Mobile financial service',
    'insurance' => 'Insurer',
    'cooperative' => 'Government scheme',
    _ => institutionType.replaceAll('_', ' '),
  };
}
