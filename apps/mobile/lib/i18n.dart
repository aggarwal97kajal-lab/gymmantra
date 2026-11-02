import 'package:flutter/widgets.dart';
import 'prefs.dart';
import 'strings_hi.dart';

/// The app's language. English text is the key; Hindi comes from [hindi].
/// A missing translation simply shows the English text.
class AppLang {
  static String get current => AppSettings.instance.lang;
}

/// Puts the settings above the whole app so every screen redraws when the
/// language (or theme) changes.
class LangScope extends InheritedNotifier<AppSettings> {
  const LangScope({super.key, required AppSettings super.notifier, required super.child});
}

String translate(String lang, String en, [Map<String, Object?>? args]) {
  var out = lang == 'hi' ? (hindi[en] ?? en) : en;
  if (args != null) {
    args.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
  }
  return out;
}

extension Tr on BuildContext {
  String t(String en, [Map<String, Object?>? args]) {
    final s = dependOnInheritedWidgetOfExactType<LangScope>()?.notifier;
    return translate(s?.lang ?? AppLang.current, en, args);
  }

  bool get isHindi => (dependOnInheritedWidgetOfExactType<LangScope>()?.notifier?.lang ?? AppLang.current) == 'hi';
}
