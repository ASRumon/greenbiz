import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/local_db.dart';
import 'core/providers.dart';
import 'core/router.dart';
import 'core/theme.dart';

/// GreenBiz - SME Finance Copilot.
///
/// Startup is deliberately minimal: load preferences (the session token lives
/// there), then render. Validating the session against the API happens *after*
/// the first frame, so a slow or unreachable server delays the splash rather
/// than blocking the app from starting at all.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SharedPreferences preferences = await SharedPreferences.getInstance();
  // Opened before the first frame so every screen can read without a spinner
  // about whether the local database exists.
  final LocalDatabase localDatabase = await LocalDatabase.open();

  runApp(
    ProviderScope(
      // The type argument is inferred: naming `Override` explicitly is not
      // portable across Riverpod majors.
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        localDatabaseProvider.overrideWithValue(localDatabase),
      ],
      child: const GreenBizApp(),
    ),
  );
}

class GreenBizApp extends StatelessWidget {
  const GreenBizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GreenBiz',
      debugShowCheckedModeBanner: false,
      theme: GreenBizTheme.light(),
      initialRoute: AppRoutes.bootstrap,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
