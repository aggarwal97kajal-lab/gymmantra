// Real app screens for the user guide (not part of the normal tests).
// The demo server (apps/worker/scripts/guide.ts) must be running on 127.0.0.1:8787 and its logins
// must be in GUIDE_LOGINS. Run: flutter test test_guide/guide_shots_test.dart --update-goldens
// The pictures land in test_guide/shots/.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gymmantra/api.dart';
import 'package:gymmantra/main.dart';
import 'package:gymmantra/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Map<String, String> secure = {};
late Map<String, dynamic> logins;

Future<void> loadFonts() async {
  final jak = FontLoader('Jakarta');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    jak.addFont(rootBundle.load('assets/fonts/PlusJakartaSans-$w.ttf'));
  }
  await jak.load();
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  final icons = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File('${dir.path}/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
  final roboto = FontLoader('Roboto');
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.contains('Roboto-'))) {
    roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
  // Hindi and emoji (downloaded by the workflow), so no empty boxes.
  for (final (family, file) in [('Noto Sans Devanagari', 'NotoSansDevanagari.ttf'), ('Noto Emoji', 'NotoEmoji.ttf')]) {
    final f = File('${Platform.environment['GUIDE_FONTS'] ?? '/tmp/guide-fonts'}/$file');
    if (f.existsSync()) await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())))).load();
  }
}

Future<void> settle(WidgetTester t, [int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pump(const Duration(milliseconds: 120));
  }
}

GoRouter routerOf(WidgetTester t) => GoRouter.of(t.element(find.byType(Navigator).last));

Future<void> shot(WidgetTester t, String name) async {
  await settle(t);
  FocusManager.instance.primaryFocus?.unfocus();
  await t.pump(const Duration(milliseconds: 300));
  await expectLater(find.byType(GymMantraApp), matchesGoldenFile('shots/$name.png'));
}

Future<void> startAs(WidgetTester t, String? role) async {
  secure
    ..clear()
    ..['api_base'] = 'http://127.0.0.1:8787'
    ..['device_id'] = 'guide-${role ?? 'none'}';
  if (role != null) secure['token'] = logins[role] as String;
  Api.instance.forget();
  Api.instance.token = null;
  Api.instance.refresh = null;
  Api.instance.branchId = null;
  await Prefs.clearUserData();
  splashDone.value = true;
  await t.pumpWidget(const ProviderScope(child: GymMantraApp()));
  await settle(t, 16);
}

Future<void> visit(WidgetTester t, String name, String path, {Object? extra, bool push = false}) async {
  final r = routerOf(t);
  if (push) {
    r.push(path, extra: extra);
  } else {
    r.go(path, extra: extra);
  }
  await shot(t, name);
}

/// Lets the app's own timers run out, so the test ends cleanly.
Future<void> finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(minutes: 4));
}

Future<dynamic> get(WidgetTester t, String path) async => (await t.runAsync(() => Api.instance.get(path)));

void main() {
  setUp(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch);
  setUpAll(() async {
    HttpOverrides.global = null; // talk to the local demo server for real
    TestWidgetsFlutterBinding.ensureInitialized();
    logins = jsonDecode(File(Platform.environment['GUIDE_LOGINS'] ?? '/tmp/guide-logins.json').readAsStringSync()) as Map<String, dynamic>;
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    AppSettings.instance.load();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
          return null;
        case 'delete':
          secure.remove(key);
          return null;
        case 'readAll':
          return secure;
        case 'containsKey':
          return secure.containsKey(key);
        case 'deleteAll':
          secure.clear();
          return null;
      }
      return null;
    });
    m.setMockMethodCallHandler(const MethodChannel('gymmantra/secure'), (call) async => call.method == 'device' ? 'Xiaomi Redmi Note 12' : null);
    await loadFonts();
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch; // no keyboard focus rings
  });

  void phone(WidgetTester t) {
    // A debug-only warning about ink on coloured boxes must not stop the pictures.
    final old = FlutterError.onError;
    FlutterError.onError = (d) {
      if ('${d.exception}'.contains('ink splashes may be invisible')) return;
      old?.call(d);
    };
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.75;
  }

  testWidgets('01 start', (t) async {
    phone(t);
    await startAs(t, null);
    await shot(t, '01_role');
    await t.tap(find.text('Continue'));
    await shot(t, '02_login');
    await visit(t, '03_signup', '/signup', push: true);
    await finish(t);
  });

  testWidgets('10 owner', (t) async {
    phone(t);
    await startAs(t, 'owner');
    final mid = logins['memberId'] as String;
    await visit(t, '10_owner_home', '/o/home');
    await visit(t, '11_owner_members', '/o/members');
    await visit(t, '12_owner_member', '/o/member/$mid', push: true);
    await visit(t, '13_owner_add_member', '/o/members/new');
    await visit(t, '14_owner_requests', '/o/requests');
    await visit(t, '15_owner_more', '/o/more');
    await visit(t, '16_owner_attendance', '/o/attendance-hub');
    await visit(t, '17_owner_reports', '/o/reports');
    await visit(t, '18_owner_plans', '/o/plans');
    await visit(t, '19_owner_offers', '/o/offers');
    await visit(t, '20_owner_notice', '/o/notices/new');
    await visit(t, '21_owner_trainers', '/o/trainers');
    await visit(t, '22_owner_pt', '/o/pt');
    await visit(t, '23_owner_pt_accounts', '/o/pt-accounts');
    await visit(t, '24_owner_staff', '/o/staff');
    await visit(t, '25_owner_salary', '/o/salary');
    await visit(t, '26_owner_staff_attendance', '/o/staff-attendance');
    await visit(t, '27_owner_lockers', '/o/lockers');
    await visit(t, '28_owner_enquiries', '/o/enquiries');
    await visit(t, '29_owner_ratings', '/o/ratings');
    await visit(t, '30_owner_settings', '/o/settings');
    await visit(t, '31_owner_branches', '/o/branches');
    await visit(t, '32_owner_gym_qr', '/o/gym-qr');
    await visit(t, '33_owner_subscription', '/o/subscription');
    await visit(t, '34_owner_notifications', '/notifications');
    await visit(t, '35_owner_devices', '/profile/devices');
    await visit(t, '36_owner_fingerprint', '/o/devices');
    await t.tap(find.text('Reception machine').first);
    await shot(t, '37_owner_machine');
    await finish(t);
  });

  testWidgets('40 staff', (t) async {
    phone(t);
    await startAs(t, 'staff');
    await visit(t, '40_staff_home', '/o/home');
    await visit(t, '41_staff_more', '/o/more');
    await visit(t, '42_staff_my_attendance', '/o/my-attendance');
    await visit(t, '43_staff_salary', '/my-salary');
    await finish(t);
  });

  testWidgets('50 trainer', (t) async {
    phone(t);
    await startAs(t, 'trainer');
    await visit(t, '50_trainer_home', '/t/home');
    await visit(t, '51_trainer_clients', '/t/clients');
    final c = await get(t, '/trainer/clients');
    final client = ((c as Map)['clients'] as List).first as Map;
    await visit(t, '52_trainer_client', '/pt-client', extra: {'pt': client, 'tenantId': c['tenantId'], 'canMark': true}, push: true);
    await visit(t, '53_trainer_attendance', '/t/my-attendance');
    await visit(t, '54_trainer_profile', '/t/profile');
    await finish(t);
  });

  testWidgets('60 member', (t) async {
    phone(t);
    await startAs(t, 'member');
    await visit(t, '60_member_home', '/home');
    await visit(t, '61_member_myqr', '/my-qr', push: true);
    await visit(t, '70_member_workouts', '/workouts');
    await visit(t, '62_member_trainers', '/trainers');
    await visit(t, '63_member_plan', '/my-plan');
    await visit(t, '64_member_membership', '/membership/${logins['memberId']}', push: true);
    await visit(t, '65_member_profile', '/profile');
    await visit(t, '66_member_rate', '/rate', extra: {'tenantId': logins['tenantId'], 'gymName': 'Lifetime Fitness'}, push: true);
    await visit(t, '67_member_join', '/join');
    await visit(t, '68_member_help', '/help');
    await visit(t, '69_member_notifications', '/notifications');
    await finish(t);
  });
}
