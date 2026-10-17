import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sale_ai.dart';

/// Persists the bring-your-own-key AI configuration.
///
/// The API key is the only secret the app owns on behalf of the user, so it
/// goes into the platform keystore rather than shared_preferences. Provider and
/// model are plain preferences.
///
/// If the keystore is unavailable (some desktop targets), the key falls back to
/// preferences so the feature still works. The UI never claims encryption — it
/// says "stored on this device", which stays true in both cases.
class AiSettingsStore {
  AiSettingsStore(this._preferences, {FlutterSecureStorage? secureStorage})
    : _secure = secureStorage ?? const FlutterSecureStorage();

  static const String _providerKey = 'greenbiz.ai.provider';
  static const String _modelKey = 'greenbiz.ai.model';
  static const String _apiKeyKey = 'greenbiz.ai.api_key';
  static const String _apiKeyFallbackKey = 'greenbiz.ai.api_key.fallback';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secure;

  Future<AiSettings> load() async {
    final provider = AiProvider.fromStorage(
      _preferences.getString(_providerKey),
    );
    final model = _preferences.getString(_modelKey) ?? '';

    var apiKey = '';
    try {
      apiKey = await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      apiKey = _preferences.getString(_apiKeyFallbackKey) ?? '';
    }

    return AiSettings(provider: provider, model: model, apiKey: apiKey);
  }

  Future<void> save(AiSettings settings) async {
    await _preferences.setString(_providerKey, settings.provider.storageValue);
    await _preferences.setString(_modelKey, settings.model.trim());

    if (settings.apiKey.trim().isEmpty) {
      await clearKey();
      return;
    }

    try {
      await _secure.write(key: _apiKeyKey, value: settings.apiKey.trim());
      await _preferences.remove(_apiKeyFallbackKey);
    } catch (_) {
      await _preferences.setString(_apiKeyFallbackKey, settings.apiKey.trim());
    }
  }

  Future<void> clearKey() async {
    try {
      await _secure.delete(key: _apiKeyKey);
    } catch (_) {
      // Nothing to delete if the keystore is unavailable.
    }
    await _preferences.remove(_apiKeyFallbackKey);
  }
}
