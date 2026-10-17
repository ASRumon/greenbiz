import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../models/shop.dart';
import '../../models/user.dart';
import '../../services/sms_live_service.dart';

enum AuthStatus {
  /// Checking a stored token. The splash screen shows during this.
  restoring,
  authenticated,
  unauthenticated,
}

/// Everything the app needs to know about "who is signed in, and which shop am
/// I looking at".
class AuthState {
  const AuthState({
    required this.status,
    this.user,
    this.shops = const <Shop>[],
    this.activeShopId,
    this.errorMessage,
    this.isBusy = false,
  });

  const AuthState.restoring() : this(status: AuthStatus.restoring);

  const AuthState.signedOut() : this(status: AuthStatus.unauthenticated);

  final AuthStatus status;
  final User? user;
  final List<Shop> shops;
  final String? activeShopId;

  /// The last failure, for inline display on the login form.
  final String? errorMessage;
  final bool isBusy;

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isRestoring => status == AuthStatus.restoring;
  bool get hasShops => shops.isNotEmpty;

  /// The shop the Inventory and Finance tabs act on.
  ///
  /// Falls back to the first shop, so the app works even before the user has
  /// ever picked one — a single-shop owner never has to make a choice.
  Shop? get activeShop {
    if (shops.isEmpty) return null;
    final id = activeShopId;
    if (id != null) {
      for (final shop in shops) {
        if (shop.id == id) return shop;
      }
    }
    return shops.first;
  }

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    List<Shop>? shops,
    String? activeShopId,
    String? errorMessage,
    bool clearError = false,
    bool? isBusy,
  }) => AuthState(
    status: status ?? this.status,
    user: user ?? this.user,
    shops: shops ?? this.shops,
    activeShopId: activeShopId ?? this.activeShopId,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    isBusy: isBusy ?? this.isBusy,
  );
}

class AuthController extends Notifier<AuthState> {
  static const String _activeShopKey = 'greenbiz.active_shop_id';

  @override
  AuthState build() {
    // Restore the stored session after the first frame rather than blocking
    // startup on a network call. The splash screen covers this.
    Future<void>.microtask(restoreSession);
    return const AuthState.restoring();
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider);

  /// Validates any stored token and loads the account.
  Future<void> restoreSession() async {
    final api = ref.read(apiClientProvider);

    if (!api.hasSession) {
      state = const AuthState.signedOut();
      return;
    }

    try {
      final snapshot = await ref.read(authServiceProvider).me();
      state = _withShops(
        snapshot.shops,
        user: snapshot.user,
        status: AuthStatus.authenticated,
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        // Token is expired or revoked: clear it and show the login screen
        // rather than retrying forever with a token that will never work.
        await api.setSessionToken(null);
        state = const AuthState.signedOut();
      } else {
        // The server is unreachable. Keep the token — this is not a sign-out —
        // and surface the problem so the user can retry.
        state = AuthState(
          status: AuthStatus.unauthenticated,
          errorMessage: error.userMessage,
        );
      }
    }
  }

  Future<bool> login({
    required String username,
    required String password,
  }) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      // The session token is stored by AuthService as a side effect of logging
      // in, so the user object is read back from /auth/me rather than trusted
      // from the login response.
      await ref
          .read(authServiceProvider)
          .login(username: username, password: password);
      final snapshot = await ref.read(authServiceProvider).me();
      state = _withShops(
        snapshot.shops,
        user: snapshot.user,
        status: AuthStatus.authenticated,
      );
      return true;
    } on ApiException catch (error) {
      state = state.copyWith(isBusy: false, errorMessage: error.userMessage);
      return false;
    }
  }

  Future<bool> register({
    required String fullName,
    required String username,
    required String password,
    String? email,
    String? shopName,
  }) async {
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      await ref
          .read(authServiceProvider)
          .register(
            fullName: fullName,
            username: username,
            password: password,
            email: email,
            shopName: shopName,
          );

      // Re-read rather than trusting the response: /auth/me returns the shop
      // list created during registration, so the app lands on a usable screen.
      final snapshot = await ref.read(authServiceProvider).me();
      state = _withShops(
        snapshot.shops,
        user: snapshot.user,
        status: AuthStatus.authenticated,
      );
      return true;
    } on ApiException catch (error) {
      state = state.copyWith(isBusy: false, errorMessage: error.userMessage);
      return false;
    }
  }

  Future<void> logout() async {
    await ref.read(authServiceProvider).logout();
    await const SmsLiveService().setTrackingEnabled(false);
    await const SmsLiveService().clearPending();
    await _preferences.remove(_activeShopKey);

    // The offline transaction service keeps a small in-memory set of report
    // ranges it has already fetched. The ledger was just wiped, so rebuild it
    // with an empty set or the next login would reuse those keys and never
    // fetch the ranges again.
    ref.invalidate(transactionServiceProvider);

    state = const AuthState.signedOut();
  }

  /// Reloads the account. Used after creating or deleting a shop.
  Future<void> refresh() async {
    try {
      final snapshot = await ref.read(authServiceProvider).me();
      state = _withShops(
        snapshot.shops,
        user: snapshot.user,
        status: AuthStatus.authenticated,
      );
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await ref.read(apiClientProvider).setSessionToken(null);
        state = const AuthState.signedOut();
      }
    }
  }

  Future<void> selectShop(String shopId) async {
    state = state.copyWith(activeShopId: shopId);
    await _preferences.setString(_activeShopKey, shopId);
  }

  void clearError() => state = state.copyWith(clearError: true);

  /// Applies a shop list and reconciles the remembered selection with it.
  ///
  /// If the remembered shop was deleted, the selection falls back to the first
  /// remaining shop instead of pointing at an id that no longer exists.
  AuthState _withShops(
    List<Shop> shops, {
    User? user,
    required AuthStatus status,
  }) {
    final remembered = _preferences.getString(_activeShopKey);
    final stillValid = shops.any((Shop shop) => shop.id == remembered);

    return AuthState(
      status: status,
      user: user,
      shops: shops,
      activeShopId: stillValid
          ? remembered
          : (shops.isNotEmpty ? shops.first.id : null),
    );
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// The active shop, or null when the user has none yet.
final activeShopProvider = Provider<Shop?>(
  (ref) => ref.watch(authControllerProvider).activeShop,
);

/// A non-null shop id for screens that cannot render without one.
final activeShopIdProvider = Provider<String?>(
  (ref) => ref.watch(authControllerProvider).activeShop?.id,
);
