import 'package:flutter/material.dart';

/// Build a polished dark theme with a soft accent palette and refined
/// typography. Designed to feel calm and unobtrusive — students may use
/// this on a bus or before bed, so we lean toward warm-dark over harsh
/// pure black.
ThemeData buildTheme() {
  const seed = Color(0xFF7AB7E0); // muted sky-blue
  final colors = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
    surface: const Color(0xFF1A1A1F),
  );

  final base = ThemeData.dark(useMaterial3: true);
  final textTheme = base.textTheme.copyWith(
    displayLarge: base.textTheme.displayLarge?.copyWith(
      fontWeight: FontWeight.w300, letterSpacing: -1.0,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w600, letterSpacing: -0.5,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600, letterSpacing: -0.3,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600, letterSpacing: -0.2,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
  );

  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: const Color(0xFF101013),
    textTheme: textTheme,
    cardTheme: CardThemeData(
      color: const Color(0xFF1A1A1F),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFF101013),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A1A1F),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.primary.withValues(alpha: 0.6), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      highlightElevation: 2,
    ),
    dividerTheme: DividerThemeData(
      color: Colors.white.withValues(alpha: 0.06),
      thickness: 1, space: 1,
    ),
  );
}
