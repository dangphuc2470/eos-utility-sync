import 'package:flutter/material.dart';

class AppTheme {
  static const Color bg = Color(0xFFF2F8F4); // light green-tinted background
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFE6F4EA); // soft green container
  static const Color border = Color(0xFFC8E6C9); // soft green border
  static const Color accent = Color(0xFF2E7D32); // deep material green
  static const Color accentMid = Color(0xFF43A047); // medium green (buttons)
  static const Color accentSoft = Color(0xFFE8F5E9); // soft green background
  static const Color accentGlow = Color(0xFFC8E6C9); // green glow / selection
  static const Color green = Color(0xFF388E3C); // success green (same family)
  static const Color greenSoft = Color(0xFFD1E7DD);
  static const Color amber = Color(0xFFFFC107); // warning yellow
  static const Color amberSoft = Color(0xFFFFF3CD);
  static const Color textPrimary = Color(0xFF1B2E1C);
  static const Color textSecondary = Color(0xFF3E5640);
  static const Color textMuted = Color(0xFF6A8A6D);

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.light(
          surface: surface,
          primary: accent,
          secondary: accentMid,
          onSurface: textPrimary,
          onSecondary: Colors.white,
          secondaryContainer: surfaceAlt,
          primaryContainer: accentSoft,
        ),
        fontFamily: 'Segoe UI',
        dividerColor: border,
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: border, width: 1.5),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: bg,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
          iconTheme: IconThemeData(color: textSecondary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: const BorderSide(color: border, width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: accent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: border, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: accent, width: 2),
          ),
          labelStyle: const TextStyle(color: textSecondary, fontSize: 14),
          hintStyle: const TextStyle(color: textMuted, fontSize: 14),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.selected)) return Colors.white;
            return textSecondary;
          }),
          trackColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.selected)) return accentMid;
            return surfaceAlt;
          }),
        ),
      );
}
