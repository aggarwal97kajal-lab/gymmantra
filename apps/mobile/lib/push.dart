import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api.dart';
import 'drip.dart';
import 'prefs.dart';
import 'theme.dart' show adminApp;

/// Phone notifications (Firebase Cloud Messaging). The server sends every in-app notification to the
/// person's phones, and gym notices / GymMantra messages to topics this phone listens to.
/// Settings come from the Firebase Android app (google-services.json), so no Gradle plugin is needed.
final _options = FirebaseOptions(
  apiKey: 'AIzaSyBlDQq21YwTODUlsVhVz2qo1_HF1fvVBvI',
  // Each Android app (com.gymmantra.gymmantra / com.gymmantra.admin) has its own Firebase app id.
  appId: adminApp ? '1:869545734393:android:3a6bac68eed665a3dd3228' : '1:869545734393:android:f05f26de050ce2b1dd3228',
  messagingSenderId: '869545734393',
  projectId: 'gymmantra',
  storageBucket: 'gymmantra.firebasestorage.app',
);

class Push {
  Push._();
  static bool _ready = false;
  static StreamSubscription<String>? _refresh;

  /// Called when a notification arrives (the session reloads the account: plan, roles, gyms).
  static void Function()? onChange;

  /// At app start. Never stops the app from opening.
  static Future<void> init() async {
    try {
      await Firebase.initializeApp(options: _options).timeout(const Duration(seconds: 8));
      _ready = true;
      // App open: show the message as a drip instead of a system notification.
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) Drip.showLater([n.title, n.body].whereType<String>().join(' — '), kind: DripKind.info);
        // Something changed for this person: the open screens load again (live update).
        Api.instance.refreshOpenScreens();
        onChange?.call();
      });
      // Tapping a notification opens the app: show fresh data.
      FirebaseMessaging.onMessageOpenedApp.listen((_) {
        Api.instance.refreshOpenScreens();
        onChange?.call();
      });
    } catch (_) {
      _ready = false;
    }
  }

  /// After log-in (and on each start): ask permission, send the token, listen to the right topics.
  static Future<void> register() async {
    if (!_ready || Api.instance.token == null) return;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final t = await fm.getToken();
      if (t != null) {
        await Api.instance.post('/me/push-token', {'token': t, 'app': adminApp ? 'admin' : 'main'});
        await Prefs.setString('push:token', t);
      }
      _refresh ??= fm.onTokenRefresh.listen((nt) async {
        try {
          await Api.instance.post('/me/push-token', {'token': nt, 'app': adminApp ? 'admin' : 'main'});
          await Prefs.setString('push:token', nt);
        } catch (_) {}
      });
      final r = await Api.instance.get('/me/push-topics');
      final want = ((r as Map)['topics'] as List).cast<String>().toSet();
      final had = (Prefs.getString('push:topics') ?? '').split(',').where((x) => x.isNotEmpty).toSet();
      for (final x in want.difference(had)) {
        await fm.subscribeToTopic(x);
      }
      for (final x in had.difference(want)) {
        await fm.unsubscribeFromTopic(x);
      }
      await Prefs.setString('push:topics', want.join(','));
    } catch (_) {}
  }

  /// Before log-out: this phone stops getting this person's notifications.
  static Future<void> unregister() async {
    if (!_ready) return;
    try {
      final t = Prefs.getString('push:token');
      if (t != null) await Api.instance.post('/me/push-token/remove', {'token': t});
      final had = (Prefs.getString('push:topics') ?? '').split(',').where((x) => x.isNotEmpty);
      for (final x in had) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(x);
      }
      await Prefs.remove('push:topics');
    } catch (_) {}
  }
}
