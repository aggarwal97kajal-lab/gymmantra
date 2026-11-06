import 'package:flutter/material.dart';

/// Built as the separate GymMantra Admin app (super admin only): --dart-define=APP=admin
const bool adminApp = String.fromEnvironment('APP') == 'admin';

/// Brand colours that are the same in light and dark mode.
class C {
  static const orange = Color(0xFFFF5A1F);
  static const orangeDeep = Color(0xFFF04E12);
  static const orangeSoft = Color(0xFFFF8A4C);
  static const ok = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const red = Color(0xFFEF4444);
  static const blue = Color(0xFF3B82F6);
  static const wa = Color(0xFF25D366);
  static const night = Color(0xFF0D1015);
  static const indigo = Color(0xFF6366F1);
  static const gold = Color(0xFFFBBF24);
}

/// Colours that change with the theme. Use `context.c.surf` etc.
class Pal {
  const Pal({required this.dark, required this.bg, required this.surf, required this.surf2, required this.line, required this.fg, required this.mut, required this.primary, required this.tint});
  final bool dark;
  final Color bg, surf, surf2, line, fg, mut, primary, tint;

  static const darkPal = Pal(
    dark: true,
    bg: Color(0xFF0D1015),
    surf: Color(0xFF161A21),
    surf2: Color(0xFF1E232C),
    line: Color(0xFF262C36),
    fg: Color(0xFFF4F6FA),
    mut: Color(0xFF8B95A5),
    primary: adminApp ? C.indigo : C.orange,
    tint: Color(0xFF2A1A12),
  );
  static const lightPal = Pal(
    dark: false,
    bg: Color(0xFFF5F6F8),
    surf: Color(0xFFFFFFFF),
    surf2: Color(0xFFF0F2F5),
    line: Color(0xFFE3E7ED),
    fg: Color(0xFF0F172A),
    mut: Color(0xFF64748B),
    primary: adminApp ? Color(0xFF4F46E5) : C.orangeDeep,
    tint: Color(0xFFFFEDE5),
  );
}

extension PalX on BuildContext {
  Pal get c => Theme.of(this).brightness == Brightness.dark ? Pal.darkPal : Pal.lightPal;
}

const fontFamily = 'Jakarta';
// Emoji and Hindi letters come from these when present (phones use their own system fonts anyway).
const fontFallback = ['Noto Sans Devanagari', 'Noto Emoji'];

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.dark ? Pal.darkPal : Pal.lightPal;
  final base = ThemeData(useMaterial3: true, brightness: b, fontFamily: fontFamily, fontFamilyFallback: fontFallback);
  final radius = BorderRadius.circular(14);
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: p.primary,
      onPrimary: Colors.white,
      secondary: p.primary,
      onSecondary: Colors.white,
      surface: p.surf,
      onSurface: p.fg,
      error: C.red,
      outline: p.line,
      surfaceContainerHighest: p.surf2,
    ),
    textTheme: base.textTheme.apply(bodyColor: p.fg, displayColor: p.fg, fontFamily: fontFamily, fontFamilyFallback: fontFallback),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.fg,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 22, fontWeight: FontWeight.w800, color: p.fg, letterSpacing: -0.4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surf,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.line)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.primary, width: 1.6)),
      labelStyle: TextStyle(color: p.mut),
      hintStyle: TextStyle(color: p.mut),
      prefixIconColor: p.mut,
      suffixIconColor: p.mut,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.primary.withAlpha(110),
        disabledForegroundColor: Colors.white70,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w700, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.fg,
        backgroundColor: p.surf,
        minimumSize: const Size.fromHeight(50),
        side: BorderSide(color: p.line),
        textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, fontSize: 15),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.primary, textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w700)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surf,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.primary.withAlpha(38),
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? p.primary : p.mut)),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(fontFamily: fontFamily, fontSize: 11.5, color: s.contains(WidgetState.selected) ? p.primary : p.mut, fontWeight: FontWeight.w600),
      ),
    ),
    dividerColor: p.line,
    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),
    dialogTheme: DialogThemeData(backgroundColor: p.surf, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.surf, surfaceTintColor: Colors.transparent, showDragHandle: true),
    listTileTheme: ListTileThemeData(iconColor: p.fg, textColor: p.fg),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.primary),
    chipTheme: base.chipTheme.copyWith(selectedColor: p.primary.withAlpha(40), side: BorderSide(color: p.line)),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.dark ? const Color(0xFF2A303B) : const Color(0xFF1E293B),
      contentTextStyle: const TextStyle(fontFamily: fontFamily, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: QuickPageTransitionsBuilder(),
    }),
  );
}

/// Fast screen change: the new screen slides in solid (no see-through fade, which looked
/// like lag) in 240 ms while the old one moves a little to the left.
class QuickPageTransitionsBuilder extends PageTransitionsBuilder {
  const QuickPageTransitionsBuilder();
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 140);
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final inA = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final outA = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return SlideTransition(
      position: Tween(begin: Offset.zero, end: const Offset(-0.22, 0)).animate(outA),
      child: SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(inA),
        child: DecoratedBox(
          decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 16)]),
          child: child,
        ),
      ),
    );
  }
}
