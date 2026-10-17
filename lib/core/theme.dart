import 'package:flutter/material.dart';

/// GreenBiz visual identity.
///
/// A single seeded Material 3 scheme keeps the three tabs visually consistent
/// without a design system, and the green seed reflects the brand without
/// hand-picking 30 colours.
class GreenBizTheme {
  const GreenBizTheme._();

  /// Deep leaf green: readable on white, distinct from the "success" green used
  /// for positive money, so a green number never looks like a button.
  static const Color seed = Color(0xFF15653D);

  /// Money received.
  static const Color inflow = Color(0xFF1B7F4B);

  /// Money sent.
  static const Color outflow = Color(0xFFB3261E);

  /// Credit-score bands, used by the score card and the factor bars.
  static const Color scoreLow = Color(0xFFB3261E);
  static const Color scoreMedium = Color(0xFFB26A00);
  static const Color scoreHigh = Color(0xFF1B7F4B);

  /// Score band colour: red under 40, amber to 69, green from 70.
  static Color forScore(int score) {
    if (score >= 70) return scoreHigh;
    if (score >= 40) return scoreMedium;
    return scoreLow;
  }

  static String labelForScore(int score) {
    if (score >= 70) return 'Strong';
    if (score >= 40) return 'Building';
    if (score > 0) return 'Early';
    return 'No data yet';
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF6F8F6),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
