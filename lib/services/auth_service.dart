import '../core/api_client.dart';
import '../models/shop.dart';
import '../models/user.dart';

/// Result of a successful register or login.
class AuthSession {
  const AuthSession({required this.user, required this.token, this.shopId});

  final User user;
  final String token;

  /// The shop created for the user at registration, when the server returns one.
  final String? shopId;
}

/// The current user plus everything they own.
class AccountSnapshot {
  const AccountSnapshot({required this.user, required this.shops});

  final User user;
  final List<Shop> shops;
}

class AuthService {
  AuthService(this._api);

  final ApiClient _api;

  Future<AuthSession> register({
    required String fullName,
    required String username,
    required String password,
    String? email,
    String? shopName,
    String? businessType,
  }) async {
    final json = await _api.post(
      '/auth/register',
      body: <String, dynamic>{
        'fullName': fullName,
        'username': username,
        'password': password,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (shopName != null && shopName.trim().isNotEmpty)
          'shopName': shopName.trim(),
        'businessType': ?businessType,
      },
    );

    final token = json['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw const ApiException(
        code: 'BAD_RESPONSE',
        message: 'Registration succeeded but no session token was returned.',
      );
    }
    await _api.setSessionToken(token);

    return AuthSession(
      user: User.fromJson(_asMap(json['user'])),
      token: token,
      shopId: asString(json['shopId']),
    );
  }

  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final json = await _api.post(
      '/auth/login',
      body: <String, dynamic>{
        'username': username.trim(),
        'password': password,
      },
    );

    final token = json['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw const ApiException(
        code: 'BAD_RESPONSE',
        message: 'Login succeeded but no session token was returned.',
      );
    }
    await _api.setSessionToken(token);

    return AuthSession(user: User.fromJson(_asMap(json['user'])), token: token);
  }

  Future<AccountSnapshot> me() async {
    final json = await _api.get('/auth/me');
    return AccountSnapshot(
      user: User.fromJson(_asMap(json['user'])),
      shops: asJsonList(
        json['shops'],
      ).map(Shop.fromJson).toList(growable: false),
    );
  }

  /// Clears the stored session.
  ///
  /// There is no server-side logout call: the session is a stateless JWT, so
  /// signing out means forgetting the token. Deleting it from the keychain is
  /// the whole operation — no request that could fail and leave the user stuck
  /// in a signed-out-but-still-stored state.
  Future<void> logout() async {
    await _api.setSessionToken(null);
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
