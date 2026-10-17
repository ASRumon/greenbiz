import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../services/sale_ai.dart';

/// Loads and saves the AI configuration used by the Sell assistant.
///
/// Async because the API key lives in the platform keystore, which is only
/// available asynchronously.
class AiSettingsController extends AsyncNotifier<AiSettings> {
  @override
  Future<AiSettings> build() => ref.read(aiSettingsStoreProvider).load();

  Future<void> save(AiSettings settings) async {
    await ref.read(aiSettingsStoreProvider).save(settings);
    state = AsyncData(settings);
  }

  Future<void> clearKey() async {
    final AiSettings current = state.value ?? const AiSettings();
    await ref.read(aiSettingsStoreProvider).clearKey();
    state = AsyncData(current.copyWith(apiKey: ''));
  }
}

final aiSettingsControllerProvider =
    AsyncNotifierProvider<AiSettingsController, AiSettings>(
      AiSettingsController.new,
    );
