import '../core/api_client.dart';
import 'credit_service.dart';

/// Structured result of parsing a single SMS through the server's two-tier
/// pipeline (regex first, LLM only as a fallback).
class SmsParseResult {
  const SmsParseResult({
    required this.provider,
    required this.currency,
    required this.direction,
    required this.amountMinor,
    this.counterparty,
    this.reference,
    required this.parseSource,
    required this.parseStatus,
    this.parseError,
    this.tier = 0,
    this.detail,
  });

  factory SmsParseResult.fromJson(Map<String, dynamic> json) {
    final extract = json['extract'] is Map
        ? Map<String, dynamic>.from(json['extract'] as Map)
        : const <String, dynamic>{};

    return SmsParseResult(
      provider: json['provider']?.toString() ?? 'unknown',
      currency: asString(json['currency']),
      direction: asString(extract['direction']),
      amountMinor: extract['amountMinor'] == null
          ? null
          : asInt(extract['amountMinor']),
      counterparty: asString(extract['counterparty']),
      reference: asString(extract['reference']),
      parseSource: asString(json['parseSource']),
      parseStatus: json['parseStatus']?.toString() ?? 'pending',
      parseError: asString(json['parseError']),
      tier: asInt(json['tier']),
      detail: asString(json['detail']),
    );
  }

  final String provider;
  final String? currency;
  final String? direction;
  final int? amountMinor;
  final String? counterparty;
  final String? reference;

  /// 'regex' or 'llm'. Null when nothing parsed it.
  final String? parseSource;

  /// 'parsed' | 'pending' | 'failed'.
  final String parseStatus;
  final String? parseError;

  /// 1 = regex handled it, 2 = LLM fallback, 0 = not a payment message.
  final int tier;
  final String? detail;

  bool get isParsed => parseStatus == 'parsed' && amountMinor != null;
  bool get wasHandledByRegex => parseSource == 'regex';
  bool get wasHandledByAi => parseSource == 'llm';

  String get tierLabel => switch (tier) {
    1 => 'Tier 1 — matched by pattern (no AI cost)',
    2 => 'Tier 2 — AI fallback',
    _ => 'Not recognised as a payment message',
  };
}

/// Advice text plus the plan ids and capacity estimate the server used.
class AiAdvice {
  const AiAdvice({required this.advice, required this.planIds, this.capacity});

  factory AiAdvice.fromJson(Map<String, dynamic> json) => AiAdvice(
    advice: json['advice']?.toString() ?? '',
    planIds: (json['planIds'] is List)
        ? (json['planIds'] as List)
              .map((id) => id.toString())
              .toList(growable: false)
        : const <String>[],
    capacity: json['capacity'] is Map
        ? LoanCapacity.fromJson(
            Map<String, dynamic>.from(json['capacity'] as Map),
          )
        : null,
  );

  final String advice;
  final List<String> planIds;
  final LoanCapacity? capacity;
}

class AiService {
  AiService(this._api);

  final ApiClient _api;

  /// True when the Worker has at least one provider key configured.
  ///
  /// The response never names the provider and never contains any part of a key.
  Future<bool> isAvailable() async {
    final json = await _api.get('/ai/status');
    return json['available'] == true;
  }

  Future<AiAdvice> recommend({
    required String shopId,
    required String intent,
    String? message,
  }) async {
    final json = await _api.post(
      '/ai/recommend',
      body: <String, dynamic>{
        'shopId': shopId,
        'intent': intent,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      },
    );
    return AiAdvice.fromJson(json);
  }

  /// Parses a message without saving anything. Used for the "try a message" tool
  /// and for checking that the parser still works after a regex change.
  Future<SmsParseResult> parseSms({
    required String sender,
    required String body,
  }) async {
    final json = await _api.post(
      '/ai/parse-sms',
      body: <String, dynamic>{'sender': sender, 'body': body},
    );
    return SmsParseResult.fromJson(json);
  }
}
