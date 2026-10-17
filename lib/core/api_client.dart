import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'env.dart';

/// A single field-level validation failure returned by the API.
class ApiFieldError {
  const ApiFieldError({required this.path, required this.message});

  final String path;
  final String message;

  factory ApiFieldError.fromJson(Map<String, dynamic> json) => ApiFieldError(
    path: json['path']?.toString() ?? '',
    message: json['message']?.toString() ?? 'Invalid value',
  );
}

/// Every API failure, normalised.
///
/// The Worker guarantees `{ error: { code, message, details? } }` for every
/// non-2xx response, so the app can show the server's own message instead of a
/// generic "something went wrong" — and can branch on [code] for the cases that
/// need different UI (expired session, no AI provider configured).
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.fieldErrors = const <ApiFieldError>[],
  });

  final String code;
  final String message;
  final int? statusCode;
  final List<ApiFieldError> fieldErrors;

  /// The session is gone: token expired, revoked, or the account was deleted.
  bool get isUnauthorized => statusCode == 401 || code == 'UNAUTHORIZED';

  /// The device could not reach the Worker at all.
  bool get isNetworkFailure => code == 'NETWORK_ERROR' || code == 'TIMEOUT';

  /// A provider fallback chain ran out; retrying later may work.
  bool get isAiUnavailable => code == 'AI_UNAVAILABLE';

  factory ApiException.fromDio(DioException error, {String? baseUrl}) {
    final response = error.response;
    final String server = (baseUrl == null || baseUrl.isEmpty)
        ? 'the GreenBiz server'
        : baseUrl;
    if (response == null) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => ApiException(
          code: 'TIMEOUT',
          message:
              'The server took too long to respond ($server). '
              'Check your connection.',
        ),
        DioExceptionType.connectionError => ApiException(
          code: 'NETWORK_ERROR',
          message:
              'Cannot reach $server. Check your internet connection, or set '
              'GREENBIZ_API_URL to a reachable server.',
        ),
        _ => ApiException(
          code: 'NETWORK_ERROR',
          message: 'Network error while contacting $server. Please try again.',
        ),
      };
    }

    final body = response.data;
    if (body is Map) {
      final error = body['error'];
      if (error is Map) {
        return ApiException(
          code: error['code']?.toString() ?? 'INTERNAL',
          message: error['message']?.toString() ?? 'Request failed.',
          statusCode: response.statusCode,
          fieldErrors: _parseFieldErrors(error['details']),
        );
      }
    }

    return ApiException(
      code: 'INTERNAL',
      message: 'Request failed with status ${response.statusCode}.',
      statusCode: response.statusCode,
    );
  }

  static List<ApiFieldError> _parseFieldErrors(dynamic details) {
    if (details is! List) return const <ApiFieldError>[];
    return details
        .whereType<Map>()
        .map(
          (entry) => ApiFieldError.fromJson(Map<String, dynamic>.from(entry)),
        )
        .toList(growable: false);
  }

  /// A message safe to show to a shop owner.
  String get userMessage => message;

  @override
  String toString() => 'ApiException($code, $statusCode): $message';
}

/// Dio wrapper: adds the bearer token, normalises errors, and keeps the API
/// surface small enough that services stay one-liners.
class ApiClient {
  ApiClient({required this.preferences, String? baseUrl})
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl ?? Env.apiBaseUrl,
          connectTimeout: const Duration(seconds: 15),
          // Generous: /api/ai/recommend waits on an upstream LLM round trip.
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 30),
          headers: <String, String>{'Content-Type': 'application/json'},
          // Let the interceptor decide what is an error so 4xx bodies are read.
          validateStatus: (status) => status != null && status < 400,
        ),
      ) {
    _token = preferences.getString(_tokenKey);

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _token;
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          if (kDebugMode) {
            // Log the method and path only. Never headers: the Authorization
            // header would put the session token in the device log.
            debugPrint('-> ${options.method} ${options.path}');
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          if (kDebugMode) {
            debugPrint(
              '<- ${response.statusCode} ${response.requestOptions.path}',
            );
          }
          handler.next(response);
        },
      ),
    );
  }

  static const String _tokenKey = 'greenbiz.session_token';

  /// The preferences store that holds the session token across launches.
  final SharedPreferences preferences;
  final Dio _dio;

  String? _token;

  /// True when a token is held. The token value itself is never exposed to the UI.
  bool get hasSession => _token != null && _token!.isNotEmpty;

  String get baseUrl => _dio.options.baseUrl;

  /// Persists the session token and applies it to subsequent requests.
  Future<void> setSessionToken(String? token) async {
    _token = token;
    if (token == null || token.isEmpty) {
      await preferences.remove(_tokenKey);
    } else {
      await preferences.setString(_tokenKey, token);
    }
  }

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => _send(() => _dio.get<dynamic>(path, queryParameters: query));

  Future<Map<String, dynamic>> post(String path, {Object? body}) =>
      _send(() => _dio.post<dynamic>(path, data: body));

  Future<Map<String, dynamic>> patch(String path, {Object? body}) =>
      _send(() => _dio.patch<dynamic>(path, data: body));

  Future<Map<String, dynamic>> delete(String path) =>
      _send(() => _dio.delete<dynamic>(path));

  Future<Map<String, dynamic>> _send(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      final response = await request();
      final data = response.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw ApiException(
        code: 'BAD_RESPONSE',
        message: 'The server returned an unexpected response.',
        statusCode: response.statusCode,
      );
    } on DioException catch (error) {
      throw ApiException.fromDio(error, baseUrl: _dio.options.baseUrl);
    }
  }
}

/// Convenience for reading typed lists out of a response body.
List<Map<String, dynamic>> asJsonList(dynamic value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((entry) => Map<String, dynamic>.from(entry))
      .toList(growable: false);
}

/// Reads an int that may arrive as a number or a numeric string.
///
/// SQLite and JSON round-trips are not always kind about integer-ness, and a
/// money field silently becoming `null` is worse than a defensive parse.
int asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double asDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

String? asString(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

DateTime? asDateTime(dynamic value) {
  if (value == null) return null;
  final millis = asInt(value, fallback: -1);
  if (millis <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}
