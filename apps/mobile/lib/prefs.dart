import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small on-phone storage: app settings (theme, language) and the last data
/// each screen showed, so screens open instantly while fresh data loads.
class Prefs {
  Prefs._();
  static SharedPreferences? _p;
  static Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {
      _p = null; // the app still works, just without the saved copy
    }
  }

  static String? getString(String k) => _p?.getString(k);
  static Future<void> setString(String k, String v) async {
    await _p?.setString(k, v);
  }

  static Future<void> remove(String k) async {
    await _p?.remove(k);
  }

  static dynamic getJson(String k) {
    final s = getString(k);
    if (s == null) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setJson(String k, Object? v) => setString(k, jsonEncode(v));

  /// Forget everything that belongs to the signed-in person (on log-out).
  static Future<void> clearUserData() async {
    final p = _p;
    if (p == null) return;
    for (final k in p.getKeys().where((k) => k.startsWith('c:') || k.startsWith('u:')).toList()) {
      await p.remove(k);
    }
  }
}

/// Theme mode and language. Changing either rebuilds the whole app at once.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  ThemeMode themeMode = ThemeMode.system;
  String lang = 'en';

  void load() {
    themeMode = switch (Prefs.getString('themeMode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    lang = Prefs.getString('lang') == 'hi' ? 'hi' : 'en';
  }

  void setTheme(ThemeMode m) {
    themeMode = m;
    Prefs.setString('themeMode', m.name);
    notifyListeners();
  }

  void setLang(String l) {
    if (l != 'en' && l != 'hi') return;
    if (lang == l) return;
    lang = l;
    Prefs.setString('lang', l);
    notifyListeners();
  }
}
