import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api.dart';
import 'drip.dart';
import 'prefs.dart';
import 'session.dart' show goFromTitle;
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

  /// A notification was tapped: open the page it is about ("go" from the server).
  static void Function(String? go, String? tenantId)? onOpen;

  /// The server ended a login of this person (password changed / logged out from another phone):
  /// the app checks its own login and, if it was this phone, logs out live.
  static void Function(String? note)? onLogout;

  /// Tapped while the app was closed: waits here until the app is ready to open it.
  static String? pendingGo;
  static String? pendingTenant;

  /// At app start. Never stops the app from opening.
  static Future<void> init() async {
    try {
      await Firebase.initializeApp(options: _options).timeout(const Duration(seconds: 8));
      _ready = true;
      // App open: show the message as a drip instead of a system notification.
      FirebaseMessaging.onMessage.listen((m) {
        if (m.data['kind'] == 'logout') {
          onLogout?.call(m.data['note'] as String?);
          return;
        }
        final n = m.notification;
        if (n != null) Drip.showLater([n.title, n.body].whereType<String>().join(' — '), kind: DripKind.info);
        // Something changed for this person: the open screens load again (live update).
        Api.instance.refreshOpenScreens();
        onChange?.call();
      });
      // Tapping a notification opens the app: show fresh data.
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        if (m.data['kind'] == 'logout') {
          onLogout?.call(m.data['note'] as String?);
          return;
        }
        Api.instance.refreshOpenScreens();
        onChange?.call();
        _open(m);
      });
      // The app was opened by tapping a notification.
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null) _open(m);
      }).catchError((_) {});
    } catch (_) {
      _ready = false;
    }
  }

  static void _open(RemoteMessage m) {
    // "go" from the server; older notifications: worked out from the title.
    final go = (m.data['go'] as String?) ?? goFromTitle(m.notification?.title);
    final tenant = m.data['tenantId'] as String?;
    if (go == null || go.isEmpty) return;
    if (onOpen != null) {
      onOpen!(go, tenant);
    } else {
      pendingGo = go;
      pendingTenant = tenant;
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
      // Subscribe to every wanted topic each start (cheap, and heals a subscription that failed before).
      await Future.wait(want.map((x) => fm.subscribeToTopic(x).catchError((_) {})));
      for (final x in had.difference(want)) {
        await fm.unsubscribeFromTopic(x);
      }
      await Prefs.setString('push:topics', want.join(','));
    } catch (_) {}
  }

  /// At log-out: this phone stops getting this person's notifications. Runs in the background with
  /// the old login, so log-out itself is instant.
  static void unregisterLater(String? bearer) {
    if (!_ready) return;
    final t = Prefs.getString('push:token');
    final had = (Prefs.getString('push:topics') ?? '').split(',').where((x) => x.isNotEmpty).toList();
    Prefs.remove('push:topics');
    () async {
      try {
        if (t != null && bearer != null) await Api.instance.postAs(bearer, '/me/push-token/remove', {'token': t});
        await Future.wait(had.map((x) => FirebaseMessaging.instance.unsubscribeFromTopic(x).catchError((_) {})));
      } catch (_) {}
    }();
  }
}
