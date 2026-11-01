import 'package:flutter/material.dart';

class C {
  static const ink = Color(0xFF0F1110);
  static const card = Color(0xFF161917);
  static const card2 = Color(0xFF202421);
  static const line = Color(0xFF262B27);
  static const fg = Color(0xFFF3F6F1);
  static const mut = Color(0xFF8C948D);
  static const lime = Color(0xFFC8FF3E);
  static const org = Color(0xFFFF7A2F);
  static const red = Color(0xFFFF5A5A);
  static const blue = Color(0xFF5BB9FF);
  static const wa = Color(0xFF6EE59A);
}

ThemeData buildTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: C.ink,
    colorScheme: base.colorScheme.copyWith(primary: C.lime, onPrimary: C.ink, surface: C.card, secondary: C.lime, error: C.red),
    appBarTheme: const AppBarTheme(backgroundColor: C.ink, foregroundColor: C.fg, elevation: 0, centerTitle: false, scrolledUnderElevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF121413),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: C.lime)),
      labelStyle: const TextStyle(color: C.mut),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: C.lime, foregroundColor: C.ink, minimumSize: const Size.fromHeight(50), textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: C.fg, minimumSize: const Size.fromHeight(48), side: const BorderSide(color: C.line), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0B0D0C),
      indicatorColor: const Color(0x26C8FF3E),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? C.lime : C.mut)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(fontSize: 12, color: s.contains(WidgetState.selected) ? C.lime : C.mut, fontWeight: FontWeight.w600)),
    ),
    dividerColor: C.line,
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
