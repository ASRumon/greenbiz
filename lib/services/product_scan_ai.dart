import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/api_client.dart';
import '../core/money.dart';
import 'sale_ai.dart';

/// Product details read from a photo of the label or packaging.
class ProductScanResult {
  const ProductScanResult({
    required this.productName,
    required this.unit,
    this.unitPriceMinor,
    this.confidence,
    this.notes,
  });

  final String productName;
  final String unit;

  /// Printed selling price, when the model could read one.
  final int? unitPriceMinor;
  final double? confidence;
  final String? notes;

  bool get isEmpty => productName.trim().isEmpty;
}

/// The prompt is deliberately strict: a wrong price silently saved into the
/// inventory is worse than an empty field the owner has to fill in.
String buildProductScanPrompt() => '''
You read a photo of a product label or packaging for a small shop's inventory.
Extract only what is clearly visible. Never invent a brand, size, or price.
Return ONLY a JSON object. No prose, no markdown.

{"productName":"<name as printed>","unit":"<piece|kg|gram|litre|packet|box|bottle|bag>","priceMajor":<number or null>,"confidence":0.0,"notes":"<short note>"}

Rules:
- productName: the product name as printed, including the brand and pack size
  if shown (for example "Fresh Milk 1L").
- unit: how the shop sells one item. Use "piece" when the label shows no weight
  or volume. Keep the pack size in productName rather than the unit.
- priceMajor: the printed selling price in major currency units (12.50, not
  1250). Use null unless a price is clearly visible on the label.
- confidence: 0 to 1. Lower it when the photo is blurry or partly hidden.
- notes: one short sentence if something is unclear; otherwise "".
- If this is not a product photo, return
  {"productName":"","unit":"","priceMajor":null,"confidence":0,"notes":"Not a product label"}.
''';

/// Sends the compressed photo straight from the device to the user's AI
/// provider. The GreenBiz Worker is not involved.
class ProductScanAiService {
  ProductScanAiService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 90),
              sendTimeout: const Duration(seconds: 60),
              responseType: ResponseType.json,
            ),
          );

  static const int _maxOutputTokens = 2048;

  final Dio _dio;

  Future<ProductScanResult> scan({
    required Uint8List jpegBytes,
    required AiSettings settings,
  }) async {
    if (!settings.isConfigured) {
      throw ApiException(
        code: 'AI_KEY_MISSING',
        message:
            'Add your own AI API key in Profile before scanning a product.',
      );
    }

    final String base64Image = base64Encode(jpegBytes);
    final String prompt = buildProductScanPrompt();

    try {
      final String raw = settings.provider == AiProvider.gemini
          ? await _askGemini(settings, base64Image, prompt)
          : await _askOpenRouter(settings, base64Image, prompt);

      return parseProductScan(raw);
    } on DioException catch (error) {
      throw _fromDio(error, settings.provider);
    }
  }

  Future<String> _askGemini(
    AiSettings settings,
    String base64Image,
    String prompt,
  ) async {
    final String model = settings.effectiveModel.replaceFirst(
      RegExp(r'^models/'),
      '',
    );

    final response = await _dio.post<dynamic>(
      'https://${AiProvider.gemini.host}/v1beta/models/$model:generateContent',
      options: Options(
        headers: <String, dynamic>{'x-goog-api-key': settings.apiKey.trim()},
      ),
      data: <String, dynamic>{
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'inlineData': <String, dynamic>{
                  'mimeType': 'image/jpeg',
                  'data': base64Image,
                },
              },
              <String, dynamic>{'text': prompt},
            ],
          },
        ],
        'generationConfig': <String, dynamic>{
          'temperature': 0.1,
          'responseMimeType': 'application/json',
          'maxOutputTokens': _maxOutputTokens,
          if (_supportsThinkingBudget(model))
            'thinkingConfig': <String, dynamic>{'thinkingBudget': 0},
        },
      },
    );

    final Map<String, dynamic> body = _asMap(response.data);
    final List<dynamic>? candidates = body['candidates'] is List
        ? body['candidates'] as List<dynamic>
        : null;

    if (candidates != null && candidates.isNotEmpty) {
      final Map<String, dynamic> candidate = _asMap(candidates.first);
      if (candidate['finishReason']?.toString() == 'MAX_TOKENS') {
        throw ApiException(
          code: 'AI_TRUNCATED',
          message: 'The AI reply hit its output limit and was cut off.',
        );
      }

      final List<dynamic>? parts = _asMap(candidate['content'])['parts'] is List
          ? _asMap(candidate['content'])['parts'] as List<dynamic>
          : null;
      if (parts != null && parts.isNotEmpty) {
        final String text = parts
            .whereType<Map>()
            .map((Map part) => part['text']?.toString() ?? '')
            .join();
        if (text.trim().isNotEmpty) return text;
      }
    }

    throw ApiException(
      code: 'AI_BAD_RESPONSE',
      message: 'Gemini returned an empty reply. Try a clearer photo.',
    );
  }

  Future<String> _askOpenRouter(
    AiSettings settings,
    String base64Image,
    String prompt,
  ) async {
    final response = await _dio.post<dynamic>(
      'https://${AiProvider.openRouter.host}/api/v1/chat/completions',
      options: Options(
        headers: <String, dynamic>{
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
          'X-Title': 'GreenBiz',
        },
      ),
      data: <String, dynamic>{
        'model': settings.effectiveModel,
        'temperature': 0.1,
        'max_tokens': 1024,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content':
                'You read product labels and reply with a JSON object only.',
          },
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': prompt},
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url': 'data:image/jpeg;base64,$base64Image',
                },
              },
            ],
          },
        ],
      },
    );

    final Map<String, dynamic> body = _asMap(response.data);
    final List<dynamic>? choices = body['choices'] is List
        ? body['choices'] as List<dynamic>
        : null;

    if (choices != null && choices.isNotEmpty) {
      final Map<String, dynamic> choice = _asMap(choices.first);
      if (choice['finish_reason']?.toString() == 'length') {
        throw ApiException(
          code: 'AI_TRUNCATED',
          message: 'The AI reply hit its output limit and was cut off.',
        );
      }

      final String content =
          _asMap(choice['message'])['content']?.toString() ?? '';
      if (content.trim().isNotEmpty) return content;
    }

    throw ApiException(
      code: 'AI_BAD_RESPONSE',
      message: 'OpenRouter returned an empty reply. Try a clearer photo.',
    );
  }

  ApiException _fromDio(DioException error, AiProvider provider) {
    final Response<dynamic>? response = error.response;
    if (response == null) {
      return ApiException(
        code: 'NETWORK_ERROR',
        message:
            'Cannot reach ${provider.host}. Check your internet connection.',
      );
    }

    final int? status = response.statusCode;

    if (status == 401 || status == 403) {
      return ApiException(
        code: 'AI_KEY_INVALID',
        message:
            '${provider.label} rejected that API key. Check it in Profile.',
        statusCode: status,
      );
    }
    if (status == 429) {
      return ApiException(
        code: 'AI_RATE_LIMIT',
        message:
            '${provider.label} is rate-limiting this key. Wait a moment and '
            'try again.',
        statusCode: status,
      );
    }
    if (status == 400 || status == 404) {
      return ApiException(
        code: 'AI_BAD_REQUEST',
        message:
            '${provider.label} could not process the photo. If you are using '
            'OpenRouter, choose a vision model such as Gemini 2.5 Flash.',
        statusCode: status,
      );
    }

    return ApiException(
      code: 'AI_UNAVAILABLE',
      message: '${provider.label} is not available right now.',
      statusCode: status,
    );
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}

/// Parses the model's JSON into a form-ready result.
ProductScanResult parseProductScan(String raw) {
  final Map<String, dynamic>? json = extractJsonObject(raw);
  if (json == null) {
    throw ApiException(
      code: 'AI_BAD_RESPONSE',
      message:
          'The AI reply was not usable JSON. Try a clearer photo or switch '
          'model in Profile.',
    );
  }

  final String name = (json['productName'] ?? json['name'] ?? '')
      .toString()
      .trim();
  final String unit = (json['unit'] ?? '').toString().trim();
  final int? priceMinor = _priceToMinor(json['priceMajor'] ?? json['price']);
  final double? confidence = _asDouble(json['confidence']);
  final String notes = (json['notes'] ?? '').toString().trim();

  return ProductScanResult(
    productName: name,
    unit: unit,
    unitPriceMinor: priceMinor,
    confidence: confidence?.clamp(0, 1).toDouble(),
    notes: notes.isEmpty ? null : notes,
  );
}

int? _priceToMinor(dynamic value) {
  if (value == null) return null;

  final String text = value.toString().replaceAll(',', '').trim();
  if (text.isEmpty) return null;

  // Prefer the exact decimal parser: "12.50" cannot drift.
  final int? exact = parseMajorToMinor(text);
  if (exact != null) return exact;

  final double? number = double.tryParse(text);
  if (number == null || number < 0) return null;
  return (number * 100).round();
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

bool _supportsThinkingBudget(String model) =>
    model.contains('2.5') &&
    (model.contains('flash') || model.contains('lite'));
