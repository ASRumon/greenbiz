import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'local_db.dart';
import 'revision.dart';
import '../services/ai_service.dart';
import '../services/ai_settings_store.dart';
import '../services/auth_service.dart';
import '../services/offline_services.dart';
import '../services/product_scan_ai.dart';
import '../services/product_service.dart';
import '../services/sale_ai.dart';
import '../services/shop_service.dart';
import '../services/sms_service.dart';
import '../services/sync_service.dart';
import '../services/transaction_service.dart';

/// Dependency wiring.
///
/// Every provider here is a plain `Provider` and therefore *not* auto-disposed:
/// `shared_preferences` and the Dio client are expensive to build and hold
/// session state that must outlive any single screen.

/// Overridden in `main()` with the loaded instance.
///
/// Throwing by default turns a missing override into an immediate, obvious
/// failure instead of a null that surfaces later as a confusing crash.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in ProviderScope. '
    'See main() in lib/main.dart.',
  ),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(preferences: ref.watch(sharedPreferencesProvider)),
);

/// Opened once in `main()` and overridden here. Every screen reads from it, so
/// it can never be null and never opens twice.
final localDatabaseProvider = Provider<LocalDatabase>(
  (ref) => throw UnimplementedError(
    'localDatabaseProvider must be overridden in ProviderScope. '
    'See main() in lib/main.dart.',
  ),
);

/// Pushes the outbox and pulls fresh server state. Local writes call
/// `kick()`; nothing in the UI waits for the network.
final syncServiceProvider = Provider<SyncService>((ref) {
  final SyncService service = SyncService(
    ref.watch(apiClientProvider),
    ref.watch(localDatabaseProvider),
  );
  service.onLocalChange = () => ref.read(dataRevisionProvider.notifier).bump();
  service.onLocalWrite = () =>
      ref.read(dataRevisionProvider.notifier).bumpNow();
  return service;
});

final authServiceProvider = Provider<OfflineAuthService>(
  (ref) => OfflineAuthService(
    AuthService(ref.watch(apiClientProvider)),
    ref.watch(localDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final shopServiceProvider = Provider<ShopService>(
  (ref) => ShopService(ref.watch(apiClientProvider)),
);

final productServiceProvider = Provider<OfflineProductService>(
  (ref) => OfflineProductService(
    ProductService(ref.watch(apiClientProvider)),
    ref.watch(localDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final transactionServiceProvider = Provider<OfflineTransactionService>(
  (ref) => OfflineTransactionService(
    TransactionService(ref.watch(apiClientProvider)),
    ref.watch(localDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final creditServiceProvider = Provider<OfflineCreditService>(
  (ref) => OfflineCreditService(
    ref.watch(apiClientProvider),
    ref.watch(localDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);

final aiServiceProvider = Provider<AiService>(
  (ref) => AiService(ref.watch(apiClientProvider)),
);

final smsServiceProvider = Provider<SmsService>(
  (ref) => SmsService(ref.watch(apiClientProvider)),
);

/// The shop owner's own AI key and provider choice, stored on this device.
final aiSettingsStoreProvider = Provider<AiSettingsStore>(
  (ref) => AiSettingsStore(ref.watch(sharedPreferencesProvider)),
);

/// The two-pass, bring-your-own-key sale assistant.
final saleAiServiceProvider = Provider<SaleAiService>((ref) => SaleAiService());

/// Reads a product label photo with the user's own AI key.
final productScanAiServiceProvider = Provider<ProductScanAiService>(
  (ref) => ProductScanAiService(),
);

/// Confirms a sale locally first, then syncs the atomic server call.
final saleServiceProvider = Provider<OfflineSaleService>(
  (ref) => OfflineSaleService(
    ref.watch(localDatabaseProvider),
    ref.watch(syncServiceProvider),
  ),
);
