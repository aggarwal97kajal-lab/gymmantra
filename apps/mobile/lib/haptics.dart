import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'prefs.dart';

/// A light vibration whenever something tappable is tapped (buttons, tabs,
/// list rows, chips), like WhatsApp. Works for every screen without changing
/// each button: it watches finished taps and checks whether they landed on
/// something that has a tap action. Can be turned off in Profile.
class TapHaptics {
  TapHaptics._();
  static Offset? _down;
  static int? _pointer;

  static void install() => GestureBinding.instance.pointerRouter.addGlobalRoute(_route);

  static void _route(PointerEvent e) {
    if (e is PointerDownEvent) {
      if (_pointer != null) return; // second finger: ignore
      _pointer = e.pointer;
      _down = e.position;
    } else if (e is PointerCancelEvent && e.pointer == _pointer) {
      _pointer = null;
    } else if (e is PointerUpEvent && e.pointer == _pointer) {
      final start = _down;
      _pointer = null;
      if (!AppSettings.instance.haptics || start == null) return;
      if ((e.position - start).distance > 18) return; // it was a scroll or swipe
      if (_tappableAt(e.position, e.viewId)) HapticFeedback.lightImpact();
    }
  }

  static bool _tappableAt(Offset position, int viewId) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      for (final entry in result.path) {
        final t = entry.target;
        if (t is RenderEditable) return false; // typing in a text box: no buzz
        if (t is RenderSemanticsGestureHandler && (t.onTap != null || t.onLongPress != null)) return true;
      }
    } catch (_) {}
    return false;
  }
}
