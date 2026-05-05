import 'package:flutter/material.dart';

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF66CCFF),
    brightness: Brightness.dark,
    surface: const Color(0xFF161616),
  );
  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: const Color(0xFF0A0A0A),
    cardTheme: CardThemeData(
      color: const Color(0xFF161616),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0A0A0A),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
  );
}
