import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart' show Logo;

/// Festival looks (set in GM Admin → Festivals, no app update needed): on those days the app opens
/// with the festival's animation and sound instead of the normal splash, Home shows a festival
/// banner, the bottom tabs turn into festival icons and every tap throws a few sparkles.
class Fest {
  Fest.fromJson(Map m)
      : id = '${m['id']}',
        kind = '${m['kind']}',
        title = '${m['title'] ?? ''}',
        sub = '${m['sub'] ?? ''}',
        from = DateTime.tryParse('${m['from']}')?.toLocal() ?? DateTime(2000),
        to = DateTime.tryParse('${m['to']}')?.toLocal() ?? DateTime(2000),
        roles = ((m['roles'] as List?) ?? const []).map((e) => '$e').toList(),
        states = ((m['states'] as List?) ?? const []).map((e) => '$e').toList(),
        sound = m['sound'] != false,
        every = m['every'] == true,
        imageV = (m['imageV'] as num?)?.toInt();
  final String id, kind, title, sub;
  final DateTime from, to;
  final List<String> roles, states;
  final bool sound, every;
  final int? imageV; // a picture the super admin uploaded (null = animation only)
  FestSpec get spec => festSpecs[kind] ?? festSpecs['diwali']!;
}

class Festivals {
  Festivals._();
  static final active = ValueNotifier<Fest?>(null);

  /// The festival opening shown over the app (cold start or coming back to the app).
  static final overlay = ValueNotifier<Fest?>(null);

  /// When the app opens: the first opening on a festival day shows its animation. If the phone
  /// does not know the festival yet (it was put live just now), it asks the server first.
  static Future<Fest?> checkOpen({Duration wait = const Duration(seconds: 3)}) async {
    if (adminApp || overlay.value != null) return null;
    var f = forSplash();
    if (f == null) {
      try {
        await refresh().timeout(wait);
      } catch (_) {}
      f = forSplash();
    }
    if (f != null) {
      try {
        await ensureImage(f).timeout(wait);
      } catch (_) {}
      overlay.value = f;
    }
    return f;
  }

  // ---- the uploaded picture, kept on the phone so the opening shows it at once (also offline)
  static final Map<String, File> _images = {};
  static File? cachedImage(Fest f) => f.imageV == null ? null : _images['${f.id}_${f.imageV}'];

  static Future<File?> ensureImage(Fest f) async {
    if (f.imageV == null) return null;
    final key = '${f.id}_${f.imageV}';
    if (_images[key] != null) return _images[key];
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/fest_$key.img');
      if (!await file.exists()) {
        final r = await Dio().get<List<int>>(Api.instance.url('/api/v1/festivals/${f.id}/image?v=${f.imageV}'), options: Options(responseType: ResponseType.bytes));
        final data = r.data;
        if (data == null || data.isEmpty) return null;
        await file.writeAsBytes(data, flush: true);
      }
      return _images[key] = file;
    } catch (_) {
      return null;
    }
  }

  static void _warmImages() {
    for (final f in _all) {
      if (f.imageV != null) ensureImage(f);
    }
  }
  static List<Fest> _all = [];
  static Map? _user;
  static Timer? _tick;

  static String get _today {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  /// At start (before the splash): the festivals saved on the phone last time.
  static void load() {
    if (adminApp) return;
    final saved = Prefs.getJson('fest:list');
    if (saved is List) _all = saved.whereType<Map>().map(Fest.fromJson).toList();
    final u = Prefs.getJson('u:me');
    _user = u is Map ? u : null;
    _pick();
    _warmImages();
    _tick ??= Timer.periodic(const Duration(minutes: 5), (_) => _pick());
  }

  /// The latest list from the server (for the next opening and for today's banner and tabs).
  static Future<void> refresh() async {
    if (adminApp) return;
    try {
      final r = await Api.instance.get('/festivals');
      if (r is! List) return;
      _all = r.whereType<Map>().map(Fest.fromJson).toList();
      await Prefs.setJson('fest:list', r);
      _pick();
      _warmImages();
    } catch (_) {}
  }

  static void setUser(Map? u) {
    _user = u;
    _pick();
  }

  static String? _role(Map? u) {
    if (u == null) return null;
    final r = u['appRole'];
    if (r is String && r.isNotEmpty) return r;
    if (u['isOwner'] == true) return 'OWNER';
    if (u['isTrainer'] == true) return 'TRAINER';
    return null;
  }

  static void _pick() {
    final now = DateTime.now();
    final role = _role(_user);
    final state = _user?['state'] as String?;
    Fest? hit;
    for (final f in _all) {
      if (now.isBefore(f.from) || now.isAfter(f.to)) continue;
      if (f.roles.isNotEmpty && (role == null || !f.roles.contains(role))) continue;
      if (f.states.isNotEmpty && (state == null || !f.states.contains(state))) continue;
      hit = f;
      break;
    }
    if (active.value?.id != hit?.id) active.value = hit;
  }

  /// The festival to open the app with, if any (once a day unless the admin chose every time).
  static Fest? forSplash() {
    final f = active.value;
    if (f == null) return null;
    if (!f.every && Prefs.getString('fest:shown:${f.id}') == _today) return null;
    Prefs.setString('fest:shown:${f.id}', _today);
    return f;
  }

  /// The sound plays once a day (also when the animation is set to every opening).
  static bool soundToday(Fest f) {
    if (!f.sound) return false;
    if (Prefs.getString('fest:sound:${f.id}') == _today) return false;
    Prefs.setString('fest:sound:${f.id}', _today);
    return true;
  }
}

/// Festival sounds (made for GymMantra, in assets/sounds). They play like a notification sound, so a
/// phone on silent or vibrate stays quiet.
class FestSound {
  FestSound._();
  static AudioPlayer? _p;
  static Future<void> play(String kind) async {
    try {
      final p = _p ??= AudioPlayer();
      await p.stop();
      await p.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationEvent,
          audioFocus: AndroidAudioFocus.none,
        ),
      ));
      await p.play(AssetSource('sounds/$kind.mp3'), volume: 0.7);
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _p?.stop();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- what each festival looks like

enum Fx { fireworks, diyas, lanterns, blobs, colorDrops, snow, sleigh, confetti, countdown, moon, stars, thread, petals, handi, feathers, toran, marigold, dandiya, garba, border, drums, arrow, flames, kites, tiranga, doves, pookalam, boat, sunrise, waves, glow, ripples, wheat }

class FestSpec {
  const FestSpec(this.name, this.bg, this.accent, this.hero, this.tabs, this.bits, this.fx, this.greet);
  final String name;
  final List<Color> bg;
  final Color accent;
  final String hero;
  final List<String> tabs;
  final List<String> bits; // little things that fly on a tap and in the banner
  final List<Fx> fx;
  final String greet;
}

const festSpecs = <String, FestSpec>{
  'diwali': FestSpec('Diwali', [Color(0xFF1F0F05), Color(0xFF3B1D06)], Color(0xFFF59E0B), '🪔', ['🪔', '🎇', '🏮', '🪔', '✨'], ['✨', '🎇', '🪔'], [Fx.lanterns, Fx.fireworks, Fx.diyas], 'Shubh Deepavali!'),
  'holi': FestSpec('Holi', [Color(0xFF7C3AED), Color(0xFFDB2777)], Color(0xFFEC4899), '🎨', ['🎨', '💦', '🔫', '🟣', '🌈'], ['💦', '🟣', '🟢', '🟡', '🩷'], [Fx.blobs, Fx.colorDrops], 'Happy Holi!'),
  'christmas': FestSpec('Christmas', [Color(0xFF0F3B2E), Color(0xFF14532D)], Color(0xFFDC2626), '🎄', ['🎄', '🎅', '⛄', '🎁', '🔔'], ['❄️', '⭐', '🎁'], [Fx.snow, Fx.sleigh, Fx.stars], 'Merry Christmas!'),
  'newyear': FestSpec('New Year', [Color(0xFF1E1B4B), Color(0xFF0B0F19)], Color(0xFFA855F7), '🎆', ['🎆', '🎉', '🥂', '🎯', '✨'], ['🎉', '✨', '🎊'], [Fx.countdown, Fx.fireworks, Fx.confetti], 'Happy New Year!'),
  'eid': FestSpec('Eid', [Color(0xFF022C22), Color(0xFF064E3B)], Color(0xFFFDE68A), '🌙', ['🌙', '🕌', '⭐', '🏮', '✨'], ['⭐', '✨', '🌙'], [Fx.stars, Fx.moon, Fx.lanterns], 'Eid Mubarak!'),
  'rakhi': FestSpec('Raksha Bandhan', [Color(0xFF9F1239), Color(0xFFE11D48)], Color(0xFFF59E0B), '🪢', ['🪢', '🎁', '🌸', '🍬', '💝'], ['🌸', '💝', '✨'], [Fx.petals, Fx.thread], 'Happy Raksha Bandhan'),
  'janmashtami': FestSpec('Janmashtami', [Color(0xFF1E3A8A), Color(0xFF1D4ED8)], Color(0xFFFDE68A), '🦚', ['🦚', '🪈', '🏺', '🧈', '✨'], ['🦚', '✨', '🧈'], [Fx.feathers, Fx.handi], 'Jai Shri Krishna'),
  'ganesh': FestSpec('Ganesh Chaturthi', [Color(0xFF7C2D12), Color(0xFFC2410C)], Color(0xFFFBBF24), '🐘', ['🐘', '🪷', '🌼', '🍬', '🪔'], ['🌼', '🌺', '🪷'], [Fx.toran, Fx.marigold, Fx.drums], 'Ganpati Bappa Morya!'),
  'navratri': FestSpec('Navratri', [Color(0xFFBE185D), Color(0xFF7C3AED)], Color(0xFFF59E0B), '💃', ['💃', '🥢', '🪔', '🔱', '🌺'], ['🥢', '✨', '🌺'], [Fx.garba, Fx.dandiya, Fx.stars], 'Shubh Navratri'),
  'durga': FestSpec('Durga Puja', [Color(0xFF7F1D1D), Color(0xFFB91C1C)], Color(0xFFFFFFFF), '🔱', ['🔱', '🥁', '🌺', '🪔', '🐚'], ['🌺', '✨', '🪔'], [Fx.border, Fx.petals, Fx.drums], 'Shubho Durga Pujo'),
  'dussehra': FestSpec('Dussehra', [Color(0xFF1C1917), Color(0xFF44403C)], Color(0xFFF97316), '🏹', ['🏹', '🔥', '👑', '🎯', '✨'], ['🔥', '✨', '🎯'], [Fx.arrow, Fx.flames, Fx.fireworks], 'Happy Dussehra'),
  'sankranti': FestSpec('Makar Sankranti', [Color(0xFF0284C7), Color(0xFF38BDF8)], Color(0xFFF59E0B), '🪁', ['🪁', '☀️', '🔥', '🍚', '🌾'], ['🪁', '☀️', '✨'], [Fx.kites], 'Happy Sankranti!'),
  'republic': FestSpec('Republic / Independence Day', [Color(0xFF0B3D91), Color(0xFF0B3D91)], Color(0xFFFF9933), '🇮🇳', ['🇮🇳', '🕊️', '☸️', '🎖️', '💪'], ['🕊️', '✨', '🇮🇳'], [Fx.tiranga, Fx.doves], 'Jai Hind!'),
  'onam': FestSpec('Onam', [Color(0xFF14532D), Color(0xFF166534)], Color(0xFFFBBF24), '🌸', ['🌸', '🛶', '🍌', '🌼', '🐘'], ['🌸', '🌼', '✨'], [Fx.pookalam, Fx.boat], 'Happy Onam!'),
  'gurpurab': FestSpec('Gurpurab', [Color(0xFF1E3A8A), Color(0xFF1E40AF)], Color(0xFFFBBF24), '🙏', ['☬', '🪔', '🙏', '✨', '🌟'], ['🪔', '✨', '🌟'], [Fx.glow, Fx.stars, Fx.diyas], 'Gurpurab di lakh lakh vadhaiyan'),
  'baisakhi': FestSpec('Baisakhi', [Color(0xFFB45309), Color(0xFFF59E0B)], Color(0xFF16A34A), '🌾', ['🌾', '🥁', '🕺', '☀️', '✨'], ['🌾', '✨', '🥁'], [Fx.wheat, Fx.drums, Fx.confetti], 'Happy Baisakhi!'),
  'chhath': FestSpec('Chhath Puja', [Color(0xFFEA580C), Color(0xFFFDBA74)], Color(0xFFFACC15), '🌅', ['🌅', '🪔', '🍌', '🌊', '🙏'], ['🪔', '✨', '🌊'], [Fx.sunrise, Fx.waves], 'Chhath Puja ki shubhkamnayein'),
  'shivratri': FestSpec('Mahashivratri', [Color(0xFF020617), Color(0xFF1E293B)], Color(0xFF60A5FA), '🔱', ['🔱', '🕉️', '🌙', '🐍', '📿'], ['✨', '🌙', '🕉️'], [Fx.stars, Fx.ripples, Fx.glow], 'Har Har Mahadev'),
};

// ---------------------------------------------------------------- drawing

/// Festival things are drawn (no emoji on the opening screen, owner said so). [e] names the thing.
void _emoji(Canvas c, String e, Offset at, double size, {double opacity = 1, double angle = 0}) {
  if (opacity <= 0.02) return;
  c.save();
  c.translate(at.dx, at.dy);
  if (angle != 0) c.rotate(angle);
  final k = size / 40; // drawings are made in a 40 x 40 box around the centre
  c.scale(k, k);
  if (opacity < 0.98) c.saveLayer(const Rect.fromLTWH(-40, -40, 80, 80), Paint()..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0, 1)));
  _drawThing(c, e);
  if (opacity < 0.98) c.restore();
  c.restore();
}

Paint _p(Color col) => Paint()..color = col;
Paint _line(Color col, double w) => Paint()
  ..color = col
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round;

void _flower(Canvas c, Color petal, Color mid, {int n = 5, double r = 9}) {
  for (var i = 0; i < n; i++) {
    c.save();
    c.rotate(2 * pi * i / n);
    c.drawOval(Rect.fromCenter(center: Offset(0, -r), width: r * 1.2, height: r * 1.9), _p(petal));
    c.restore();
  }
  c.drawCircle(Offset.zero, r * 0.55, _p(mid));
}

void _flame(Canvas c, {double h = 18, Color out = const Color(0xFFF97316), Color inner = const Color(0xFFFDE047)}) {
  final p = Path()
    ..moveTo(0, -h)
    ..cubicTo(h * 0.5, -h * 0.4, h * 0.45, 0, 0, h * 0.2)
    ..cubicTo(-h * 0.45, 0, -h * 0.5, -h * 0.4, 0, -h);
  c.drawPath(p, _p(out));
  c.save();
  c.scale(0.55, 0.6);
  c.translate(0, h * 0.25);
  c.drawPath(p, _p(inner));
  c.restore();
}

void _drawThing(Canvas c, String e) {
  switch (e) {
    case '🪔':
    case 'diya-off':
      if (e == '🪔') {
        c.drawCircle(const Offset(0, -10), 14, Paint()..color = const Color(0x99F59E0B)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
        c.save();
        c.translate(0, -6);
        _flame(c, h: 12, out: const Color(0xFFFDE047), inner: Colors.white);
        c.restore();
      }
      final bowl = Path()
        ..moveTo(-19, 0)
        ..quadraticBezierTo(0, 9, 19, 0)
        ..quadraticBezierTo(16, 14, 0, 15)
        ..quadraticBezierTo(-16, 14, -19, 0);
      c.drawPath(bowl, _p(const Color(0xFFB45309)));
      c.drawPath(Path()..moveTo(-19, 0)..quadraticBezierTo(0, 9, 19, 0), _line(const Color(0xFFFDE68A), 1.6));
    case '🏮':
      c.drawCircle(Offset.zero, 18, Paint()..color = const Color(0x66F59E0B)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-10, -13, 20, 26), const Radius.circular(8)), _p(const Color(0xFFDC2626)));
      for (final y in [-6.0, 0.0, 6.0]) {
        c.drawLine(Offset(-9, y), Offset(9, y), _line(const Color(0x66FDE68A), 1));
      }
      c.drawRect(const Rect.fromLTWH(-7, -16, 14, 4), _p(const Color(0xFFFBBF24)));
      c.drawRect(const Rect.fromLTWH(-7, 12, 14, 4), _p(const Color(0xFFFBBF24)));
      c.drawLine(const Offset(0, 16), const Offset(0, 24), _line(const Color(0xFFFBBF24), 1.5));
    case '❄️':
      for (var i = 0; i < 3; i++) {
        c.save();
        c.rotate(pi / 3 * i);
        c.drawLine(const Offset(0, -18), const Offset(0, 18), _line(Colors.white, 2.4));
        for (final y in [-11.0, 11.0]) {
          c.drawLine(Offset(0, y), Offset(-5, y + (y < 0 ? -5 : 5)), _line(Colors.white, 1.8));
          c.drawLine(Offset(0, y), Offset(5, y + (y < 0 ? -5 : 5)), _line(Colors.white, 1.8));
        }
        c.restore();
      }
    case '🛷':
      final body = Path()
        ..moveTo(-20, -2)
        ..lineTo(14, -2)
        ..quadraticBezierTo(22, -2, 20, -12)
        ..lineTo(24, -12)
        ..quadraticBezierTo(26, 6, 10, 6)
        ..lineTo(-18, 6)
        ..close();
      c.drawPath(body, _p(const Color(0xFFB91C1C)));
      c.drawPath(Path()..moveTo(-22, 12)..lineTo(16, 12)..quadraticBezierTo(24, 12, 24, 6), _line(const Color(0xFFFBBF24), 2.2));
    case '🎅':
      c.drawCircle(const Offset(0, 6), 10, _p(const Color(0xFFDC2626)));
      c.drawCircle(const Offset(0, -6), 7, _p(const Color(0xFFF5C7A9)));
      c.drawPath(Path()..moveTo(-7, -4)..quadraticBezierTo(0, 8, 7, -4)..close(), _p(Colors.white));
      c.drawPath(Path()..moveTo(-8, -9)..lineTo(8, -9)..lineTo(10, -20)..close(), _p(const Color(0xFFDC2626)));
      c.drawCircle(const Offset(10, -20), 2.5, _p(Colors.white));
    case '🌙':
      final moon = Path.combine(PathOperation.difference, Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: 18)), Path()..addOval(Rect.fromCircle(center: const Offset(8, -6), radius: 15)));
      c.drawPath(moon, _p(const Color(0xFFFDE68A)));
    case '🌸':
      _flower(c, const Color(0xFFF9A8D4), const Color(0xFFFDE047));
    case '🌺':
      _flower(c, const Color(0xFFEF4444), const Color(0xFFFDE047));
    case '🪷':
      _flower(c, const Color(0xFFF472B6), const Color(0xFFFBBF24), n: 8, r: 8);
    case '🌼':
      _flower(c, const Color(0xFFF97316), const Color(0xFFEA580C), n: 12, r: 7);
      c.drawCircle(Offset.zero, 4, _p(const Color(0xFFFBBF24)));
    case '🍃':
      c.drawOval(const Rect.fromLTWH(-5, -12, 10, 24), _p(const Color(0xFF16A34A)));
    case '🦚':
      final f = Path()
        ..moveTo(0, 20)
        ..cubicTo(-12, 6, -11, -14, 0, -22)
        ..cubicTo(11, -14, 12, 6, 0, 20);
      c.drawPath(f, _p(const Color(0xFF15803D)));
      c.drawLine(const Offset(0, 20), const Offset(0, -18), _line(const Color(0xFFA3E635), 1));
      c.drawOval(const Rect.fromLTWH(-6, -14, 12, 15), _p(const Color(0xFF0EA5E9)));
      c.drawOval(const Rect.fromLTWH(-4, -11, 8, 10), _p(const Color(0xFF1E3A8A)));
      c.drawOval(const Rect.fromLTWH(-2, -8, 4, 5), _p(const Color(0xFFFDE047)));
    case '✨':
    case '⭐':
      final st = Path();
      for (var i = 0; i < 8; i++) {
        final rr = i.isEven ? 16.0 : 4.0;
        final a = pi / 4 * i - pi / 2;
        i == 0 ? st.moveTo(cos(a) * rr, sin(a) * rr) : st.lineTo(cos(a) * rr, sin(a) * rr);
      }
      st.close();
      c.drawPath(st, _p(const Color(0xFFFDE68A)));
    case '🔥':
      c.drawCircle(Offset.zero, 18, Paint()..color = const Color(0x66F97316)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      c.translate(0, 4);
      _flame(c, h: 20);
    case '🕊️':
      c.drawOval(const Rect.fromLTWH(-12, -4, 24, 10), _p(Colors.white));
      c.drawPath(Path()..moveTo(-4, -2)..quadraticBezierTo(-2, -18, 10, -16)..quadraticBezierTo(4, -8, 6, 0)..close(), _p(const Color(0xFFE2E8F0)));
      c.drawCircle(const Offset(12, -2), 4, _p(Colors.white));
      c.drawPath(Path()..moveTo(15, -2)..lineTo(19, -1)..lineTo(15, 0)..close(), _p(const Color(0xFFF59E0B)));
    case '🏺':
      c.drawPath(Path()..moveTo(-16, -8)..lineTo(16, -8)..quadraticBezierTo(22, 18, 0, 20)..quadraticBezierTo(-22, 18, -16, -8), _p(const Color(0xFFB45309)));
      c.drawLine(const Offset(-16, -4), const Offset(16, -4), _line(const Color(0xFFDC2626), 3));
      c.drawPath(Path()..moveTo(-12, -8)..quadraticBezierTo(0, -20, 12, -8)..close(), _p(Colors.white));
    case '💥':
      for (var i = 0; i < 12; i++) {
        final a = 2 * pi * i / 12;
        c.drawLine(Offset(cos(a) * 6, sin(a) * 6), Offset(cos(a) * 20, sin(a) * 20), _line(i.isEven ? const Color(0xFFFDE047) : Colors.white, 3));
      }
    case '🥢':
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-2.5, -20, 5, 40), const Radius.circular(2.5)), _p(const Color(0xFFDC2626)));
      for (final y in [-12.0, 0.0, 12.0]) {
        c.drawRect(Rect.fromLTWH(-2.5, y - 1.5, 5, 3), _p(const Color(0xFFFBBF24)));
      }
    case '🥁':
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-18, -10, 36, 20), const Radius.circular(10)), _p(const Color(0xFFB45309)));
      for (var i = 0; i < 6; i++) {
        c.drawLine(Offset(-12 + i * 5.0, -9), Offset(-9 + i * 5.0, 9), _line(const Color(0xFFFDE68A), 1.2));
      }
      c.drawOval(const Rect.fromLTWH(-21, -10, 6, 20), _p(const Color(0xFF7C2D12)));
      c.drawOval(const Rect.fromLTWH(15, -10, 6, 20), _p(const Color(0xFF7C2D12)));
    case '👹':
      c.drawCircle(Offset.zero, 16, _p(const Color(0xFF15803D)));
      c.drawPath(Path()..moveTo(-12, -12)..lineTo(-8, -24)..lineTo(-3, -16)..lineTo(0, -26)..lineTo(3, -16)..lineTo(8, -24)..lineTo(12, -12)..close(), _p(const Color(0xFFFBBF24)));
      c.drawCircle(const Offset(-6, -3), 3, _p(Colors.white));
      c.drawCircle(const Offset(6, -3), 3, _p(Colors.white));
      c.drawCircle(const Offset(-6, -3), 1.4, _p(Colors.black));
      c.drawCircle(const Offset(6, -3), 1.4, _p(Colors.black));
      c.drawPath(Path()..moveTo(-9, 7)..quadraticBezierTo(0, 2, 9, 7), _line(Colors.black, 2.2));
    case '🏹':
      c.drawLine(const Offset(-20, 0), const Offset(16, 0), _line(const Color(0xFFFDE68A), 2.2));
      c.drawPath(Path()..moveTo(22, 0)..lineTo(14, -4)..lineTo(14, 4)..close(), _p(const Color(0xFFE5E7EB)));
      c.drawLine(const Offset(-20, 0), const Offset(-25, -5), _line(const Color(0xFFDC2626), 2));
      c.drawLine(const Offset(-20, 0), const Offset(-25, 5), _line(const Color(0xFFDC2626), 2));
    case '🪁':
      c.drawPath(Path()..moveTo(0, -18)..lineTo(13, 0)..lineTo(0, 20)..lineTo(-13, 0)..close(), _p(const Color(0xFFEF4444)));
      c.drawPath(Path()..moveTo(0, -18)..lineTo(13, 0)..lineTo(0, 0)..close(), _p(const Color(0xFFFBBF24)));
      c.drawLine(const Offset(0, -18), const Offset(0, 20), _line(Colors.white, 0.8));
      c.drawLine(const Offset(-13, 0), const Offset(13, 0), _line(Colors.white, 0.8));
      c.drawPath(Path()..moveTo(0, 20)..quadraticBezierTo(-6, 28, 2, 32)..quadraticBezierTo(8, 36, 0, 42), _line(const Color(0xFFFBBF24), 1.5));
    case '☀️':
      for (var i = 0; i < 12; i++) {
        final a = 2 * pi * i / 12;
        c.drawLine(Offset(cos(a) * 14, sin(a) * 14), Offset(cos(a) * 20, sin(a) * 20), _line(const Color(0xFFFDE047), 2.4));
      }
      c.drawCircle(Offset.zero, 11, _p(const Color(0xFFFDE047)));
    case '🌾':
      c.drawLine(const Offset(0, 20), const Offset(0, -16), _line(const Color(0xFFA16207), 1.6));
      for (var i = 0; i < 5; i++) {
        final y = -16.0 + i * 5;
        c.drawOval(Rect.fromCenter(center: Offset(-3, y), width: 4, height: 7), _p(const Color(0xFFCA8A04)));
        c.drawOval(Rect.fromCenter(center: Offset(3, y + 2), width: 4, height: 7), _p(const Color(0xFFCA8A04)));
      }
    case '🛶':
      c.drawPath(Path()..moveTo(-26, -2)..quadraticBezierTo(0, 8, 24, -2)..lineTo(28, -12)..quadraticBezierTo(26, 6, 0, 8)..quadraticBezierTo(-22, 8, -26, -2), _p(const Color(0xFF1F1305)));
      c.drawLine(const Offset(-22, 1), const Offset(22, 1), _line(const Color(0xFFFBBF24), 1));
    default:
      // anything else: a small golden sparkle
      c.drawCircle(Offset.zero, 6, _p(const Color(0xFFFDE68A)));
  }
}

double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
double _ease(double x) => 1 - pow(1 - _clamp01(x), 3).toDouble();

const _sparkColors = [Color(0xFFFDE68A), Color(0xFFF59E0B), Color(0xFFFB923C), Color(0xFFFFFFFF), Color(0xFFF472B6), Color(0xFF60A5FA), Color(0xFF34D399)];
const _holiColors = [Color(0xFFEC4899), Color(0xFF8B5CF6), Color(0xFFF59E0B), Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFFEF4444)];

/// Paints a festival scene. [s] = seconds since it started; [lite] = small banner version.
class FestPainter extends CustomPainter {
  FestPainter(this.spec, this.s, {this.lite = false});
  final FestSpec spec;
  final double s;
  final bool lite;

  @override
  void paint(Canvas c, Size z) {
    final r = Random(11);
    for (final fx in spec.fx) {
      switch (fx) {
        case Fx.fireworks:
          _fireworks(c, z, lite ? 0.0 : (spec.fx.contains(Fx.countdown) ? 1.2 : 0.2));
        case Fx.diyas:
          if (!lite) _diyas(c, z);
        case Fx.lanterns:
          _lanterns(c, z, spec.fx.contains(Fx.moon) ? '🏮' : '🏮');
        case Fx.blobs:
          _blobs(c, z);
        case Fx.colorDrops:
          _rain(c, z, r, const ['•'], lite ? 14 : 40, speed: 0.35, colors: _holiColors, size: 7);
        case Fx.snow:
          _rain(c, z, r, const ['❄️', '•', '•'], lite ? 10 : 36, speed: 0.12, colors: const [Colors.white], size: lite ? 10 : 14);
        case Fx.sleigh:
          if (!lite) _across(c, z, '🛷', z.height * 0.16, 0.6, 2.6, 34, extra: '🎅');
        case Fx.confetti:
          _rain(c, z, r, const ['▮', '•', '◆'], lite ? 14 : 46, speed: 0.3, colors: _sparkColors, size: 9, start: spec.fx.contains(Fx.countdown) ? 1.2 : 0);
        case Fx.countdown:
          if (!lite) _countdown(c, z);
        case Fx.moon:
          _moon(c, z);
        case Fx.stars:
          _stars(c, z, r, lite ? 10 : 30);
        case Fx.thread:
          _thread(c, z);
        case Fx.petals:
          _rain(c, z, r, const ['🌸', '🌺'], lite ? 6 : 16, speed: 0.12, size: lite ? 12 : 20);
        case Fx.handi:
          if (!lite) _handi(c, z);
        case Fx.feathers:
          _rain(c, z, r, const ['🦚', '✨'], lite ? 5 : 10, speed: -0.08, size: lite ? 14 : 24);
        case Fx.toran:
          _toran(c, z);
        case Fx.marigold:
          _rain(c, z, r, const ['🌼', '🌺', '🪷'], lite ? 6 : 22, speed: 0.16, size: lite ? 12 : 20);
        case Fx.dandiya:
          if (!lite) _dandiya(c, z);
        case Fx.garba:
          _garba(c, z);
        case Fx.border:
          _border(c, z);
        case Fx.drums:
          if (!lite) _beat(c, z, spec.tabs[1]);
        case Fx.arrow:
          if (!lite) _arrow(c, z);
        case Fx.flames:
          _rain(c, z, r, const ['🔥', '✨', '•'], lite ? 8 : 26, speed: -0.25, colors: const [Color(0xFFF97316), Color(0xFFFDE047)], size: lite ? 12 : 18, start: lite ? 0 : 1.0);
        case Fx.kites:
          _kites(c, z);
        case Fx.tiranga:
          _tiranga(c, z);
        case Fx.doves:
          _rain(c, z, r, const ['🕊️'], lite ? 3 : 6, speed: -0.1, size: lite ? 14 : 26);
        case Fx.pookalam:
          _pookalam(c, z);
        case Fx.boat:
          if (!lite) _across(c, z, '🛶', z.height * 0.86, 0.3, 3.0, 36);
        case Fx.sunrise:
          _sunrise(c, z);
        case Fx.waves:
          _waves(c, z);
        case Fx.glow:
          _glow(c, z);
        case Fx.ripples:
          _ripples(c, z);
        case Fx.wheat:
          _wheat(c, z);
      }
    }
  }

  // Rockets go up and burst into gold rings of sparks.
  void _fireworks(Canvas c, Size z, double start) {
    final shots = lite ? 2 : 4;
    final period = lite ? 2.6 : 9.0;
    for (var i = 0; i < shots; i++) {
      final t0 = start + i * (lite ? 1.3 : 0.45);
      var t = s - t0;
      if (lite) t = t % period;
      if (t < 0) continue;
      final x = z.width * [0.3, 0.7, 0.5, 0.18, 0.82][i % 5];
      final top = z.height * (lite ? 0.35 : [0.28, 0.22, 0.34, 0.4, 0.3][i % 5]);
      const rise = 0.6;
      if (t < rise) {
        final y = z.height - (z.height - top) * _ease(t / rise);
        c.drawLine(Offset(x, y), Offset(x, y + 40), Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFFFDE68A), const Color(0x00FDE68A)]).createShader(Rect.fromLTWH(x, y, 2, 40))
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
        c.drawCircle(Offset(x, y), 3.5, Paint()..color = Colors.white);
        continue;
      }
      final b = t - rise;
      if (b > 1.6) continue;
      final fade = 1 - _clamp01(b / 1.6);
      final n = lite ? 18 : 34;
      final col = _sparkColors[i % _sparkColors.length];
      final radius = (lite ? 40 : 120) * _ease(b / 0.9);
      // flash
      if (b < 0.15) c.drawCircle(Offset(x, top), 30 * (1 - b / 0.15), Paint()..color = Colors.white.withAlpha(180)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
      for (var k = 0; k < n; k++) {
        final a = 2 * pi * k / n;
        final p = Offset(x + cos(a) * radius, top + sin(a) * radius + 30 * b * b);
        final tail = Offset(x + cos(a) * radius * 0.82, top + sin(a) * radius * 0.82 + 30 * b * b);
        c.drawLine(tail, p, Paint()
          ..color = col.withAlpha((255 * fade).round())
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
        c.drawCircle(p, 2.2, Paint()..color = Colors.white.withAlpha((230 * fade).round()));
      }
    }
  }

  // Five diyas at the bottom light up one by one, flames flicker.
  void _diyas(Canvas c, Size z) {
    for (var i = 0; i < 5; i++) {
      final x = z.width * (0.16 + i * 0.17);
      final y = z.height * 0.9;
      final lit = s > 0.9 + i * 0.22;
      if (lit) {
        final f = 0.85 + 0.15 * sin(s * 18 + i);
        c.drawCircle(Offset(x, y - 14), 26 * f, Paint()..color = const Color(0xFFF59E0B).withAlpha(120)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
      }
      _emoji(c, lit ? '🪔' : 'diya-off', Offset(x, y), 40, opacity: lit ? 1 : 0.45);
    }
  }

  void _lanterns(Canvas c, Size z, String e) {
    final n = lite ? 4 : 6;
    for (var i = 0; i < n; i++) {
      final x = z.width * (i + 0.5) / n;
      final len = 18.0 + (i % 3) * 14;
      final sw = sin(s * 2 + i) * 0.12;
      final end = Offset(x + sin(sw) * len, len * cos(sw));
      c.drawLine(Offset(x, 0), end, Paint()..color = const Color(0xFFFCD34D)..strokeWidth = 1);
      c.drawCircle(end + const Offset(0, 12), 16, Paint()..color = const Color(0xFFF59E0B).withAlpha(70)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      _emoji(c, e, end + const Offset(0, 12), lite ? 16 : 22, angle: sw);
    }
  }

  // Holi: clouds of gulal burst in from the edges.
  void _blobs(Canvas c, Size z) {
    final pts = [const Offset(0.05, 0.1), const Offset(0.95, 0.15), const Offset(0.1, 0.85), const Offset(0.9, 0.8), const Offset(0.5, 0.45), const Offset(0.3, 0.3)];
    for (var i = 0; i < pts.length; i++) {
      final t = lite ? 1.0 : _ease((s - i * 0.12) / 1.0);
      final breathe = 1 + 0.06 * sin(s * 1.5 + i);
      c.drawCircle(Offset(pts[i].dx * z.width, pts[i].dy * z.height), (lite ? 40 : 150) * t * breathe, Paint()
        ..color = _holiColors[i % _holiColors.length].withAlpha(lite ? 120 : 170)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, lite ? 18 : 40));
    }
  }

  // Things falling (speed > 0) or rising (speed < 0) with a gentle sway.
  void _rain(Canvas c, Size z, Random r, List<String> items, int n, {double speed = 0.2, List<Color>? colors, double size = 16, double start = 0}) {
    if (s < start) return;
    final t = s - start;
    for (var i = 0; i < n; i++) {
      final x0 = r.nextDouble() * z.width;
      final y0 = r.nextDouble();
      final ph = r.nextDouble() * 6;
      final sz = size * (0.6 + r.nextDouble() * 0.7);
      var y = (y0 + speed * t * (0.7 + 0.6 * ((i * 37) % 10) / 10)) % 1.0;
      if (y < 0) y += 1;
      final pos = Offset(x0 + sin(t * 1.4 + ph) * 14, -20 + y * (z.height + 40));
      final e = items[i % items.length];
      if (e == '•' || e == '▮' || e == '◆') {
        final col = (colors ?? _sparkColors)[i % (colors ?? _sparkColors).length];
        final p = Paint()..color = col.withAlpha(220);
        if (e == '•') {
          c.drawCircle(pos, sz / 3, p);
        } else {
          c.save();
          c.translate(pos.dx, pos.dy);
          c.rotate(t * 3 + ph);
          c.drawRect(Rect.fromCenter(center: Offset.zero, width: sz * 0.45, height: sz * 0.8), p);
          c.restore();
        }
      } else {
        _emoji(c, e, pos, sz, angle: sin(t + ph) * 0.4);
      }
    }
  }

  void _across(Canvas c, Size z, String e, double y, double t0, double dur, double size, {String? extra}) {
    final t = (s - t0) / dur;
    if (t < 0 || t > 1) return;
    final x = -40 + (z.width + 80) * t;
    _emoji(c, e, Offset(x, y + sin(t * 12) * 4), size);
    if (extra != null) _emoji(c, extra, Offset(x + size * 0.8, y - 6 + sin(t * 12) * 4), size * 0.8);
  }

  void _countdown(Canvas c, Size z) {
    if (s > 1.2) return;
    final n = 3 - (s / 0.4).floor();
    final k = (s % 0.4) / 0.4;
    final tp = TextPainter(
      text: TextSpan(text: '$n', style: TextStyle(fontSize: 120 + 60 * k, fontWeight: FontWeight.w800, color: Colors.white.withAlpha((255 * (1 - k)).round()))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(z.width / 2 - tp.width / 2, z.height * 0.4 - tp.height / 2));
  }

  void _moon(Canvas c, Size z) {
    final t = lite ? 1.0 : _ease(s / 1.4);
    final p = Offset(z.width * (lite ? 0.88 : 0.75), (lite ? 0.35 : 0.42 - 0.24 * t) * z.height);
    c.drawCircle(p, lite ? 26 : 70, Paint()..color = const Color(0xFFFDE68A).withAlpha(90)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30));
    _emoji(c, '🌙', p, lite ? 30 : 70);
  }

  void _stars(Canvas c, Size z, Random r, int n) {
    for (var i = 0; i < n; i++) {
      final p = Offset(r.nextDouble() * z.width, r.nextDouble() * z.height * (lite ? 1 : 0.6));
      final on = lite ? 1.0 : _clamp01((s - i * 0.04) / 0.3);
      final tw = 0.5 + 0.5 * sin(s * 4 + i * 1.7);
      final rad = 1.2 + 1.6 * tw;
      c.drawCircle(p, rad * 2.5, Paint()..color = Colors.white.withAlpha((50 * on * tw).round())..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      c.drawCircle(p, rad, Paint()..color = Colors.white.withAlpha((230 * on).round()));
    }
  }

  // Rakhi: a red-gold thread draws itself across and a flower ties it in the middle.
  void _thread(Canvas c, Size z) {
    final t = lite ? 1.0 : _ease(s / 1.2);
    final y = z.height * (lite ? 0.5 : 0.3);
    final path = Path()..moveTo(0, y);
    for (var x = 0.0; x <= z.width * t; x += 8) {
      path.lineTo(x, y + sin(x / 30 + s * 2) * 6);
    }
    c.drawPath(path, Paint()..color = const Color(0xFFE11D48)..style = PaintingStyle.stroke..strokeWidth = lite ? 3 : 5);
    c.drawPath(path, Paint()..color = const Color(0xFFFBBF24)..style = PaintingStyle.stroke..strokeWidth = lite ? 1 : 1.6);
    if (t > 0.5) {
      final k = _ease((t - 0.5) * 2);
      _emoji(c, '🌸', Offset(z.width / 2, y + sin(z.width / 60 + s * 2) * 6), (lite ? 22 : 56) * k, angle: s);
    }
  }

  // Janmashtami: the dahi-handi swings, then breaks into butter drops.
  void _handi(Canvas c, Size z) {
    final top = Offset(z.width / 2, 0);
    final sw = sin(s * 3) * 0.25 * (s < 1.3 ? 1 : 0);
    final len = z.height * 0.28;
    final p = top + Offset(sin(sw) * len, cos(sw) * len);
    c.drawLine(Offset(0, 6), top, Paint()..color = const Color(0xFFFDE68A)..strokeWidth = 1.5);
    c.drawLine(Offset(z.width, 6), top, Paint()..color = const Color(0xFFFDE68A)..strokeWidth = 1.5);
    if (s < 1.3) {
      c.drawLine(top, p, Paint()..color = const Color(0xFFFDE68A)..strokeWidth = 1.5);
      _emoji(c, '🏺', p, 60, angle: sw);
      return;
    }
    final b = s - 1.3;
    for (var k = 0; k < 26; k++) {
      final a = -pi / 2 + (k / 25 - 0.5) * pi * 1.6;
      final v = 150.0 + (k * 23) % 90;
      final q = p + Offset(cos(a) * v * b, sin(a) * v * b + 260 * b * b);
      c.drawCircle(q, 4.5, Paint()..color = (k % 3 == 0 ? const Color(0xFFFDE68A) : Colors.white).withAlpha((255 * (1 - _clamp01(b / 1.8))).round()));
    }
    if (b < 0.4) _emoji(c, '💥', p, 70 * (0.5 + b * 2), opacity: 1 - b / 0.4);
  }

  void _toran(Canvas c, Size z) {
    final n = (z.width / 22).ceil();
    for (var i = 0; i < n; i++) {
      final x = i * 22.0 + 11;
      final drop = lite ? 1.0 : _ease((s - i * 0.03) / 0.5);
      final y = 6 + (i.isEven ? 10 : 18) * drop;
      c.drawLine(Offset(x, 0), Offset(x, y), Paint()..color = const Color(0xFF16A34A)..strokeWidth = 1);
      _emoji(c, i.isEven ? '🌼' : '🍃', Offset(x, y + 6), lite ? 11 : 16);
    }
  }

  void _dandiya(Canvas c, Size z) {
    final cx = z.width / 2, cy = z.height * 0.3;
    final hit = (s * 2.5) % 1.0;
    final a = 0.9 * (1 - (hit < 0.5 ? hit * 2 : (1 - hit) * 2));
    _emoji(c, '🥢', Offset(cx - 34, cy), 64, angle: -0.6 + a);
    _emoji(c, '🥢', Offset(cx + 34, cy), 64, angle: 0.6 - a + pi / 2);
    if (hit > 0.42 && hit < 0.62) {
      for (var k = 0; k < 10; k++) {
        final ang = 2 * pi * k / 10;
        c.drawLine(Offset(cx, cy - 20) + Offset(cos(ang), sin(ang)) * 12, Offset(cx, cy - 20) + Offset(cos(ang), sin(ang)) * 30, Paint()..color = const Color(0xFFFDE68A)..strokeWidth = 2.5..strokeCap = StrokeCap.round);
      }
    }
  }

  // Navratri: dancers' colours going round in a garba circle.
  void _garba(Canvas c, Size z) {
    final cx = z.width / 2, cy = z.height * (lite ? 0.5 : 0.3);
    final rad = lite ? 28.0 : 120.0;
    const cols = [Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFF22C55E), Color(0xFF3B82F6), Color(0xFFEC4899), Color(0xFFA855F7), Color(0xFFFDE047), Color(0xFF14B8A6), Color(0xFFFFFFFF)];
    for (var i = 0; i < 18; i++) {
      final a = 2 * pi * i / 18 + s * 0.9;
      final p = Offset(cx + cos(a) * rad, cy + sin(a) * rad * 0.45);
      c.drawCircle(p, lite ? 3 : 7, Paint()..color = cols[i % cols.length]);
    }
  }

  void _border(Canvas c, Size z) {
    final t = lite ? 1.0 : _ease(s / 0.8);
    final w = z.width * t;
    for (var x = 0.0; x < w; x += 20) {
      c.drawRect(Rect.fromLTWH(x, 0, 10, 14), Paint()..color = Colors.white);
      c.drawRect(Rect.fromLTWH(z.width - x - 10, z.height - 14, 10, 14), Paint()..color = Colors.white);
    }
  }

  void _beat(Canvas c, Size z, String e) {
    final k = (s * 3) % 1.0;
    final sc = 1 + 0.25 * (k < 0.2 ? (1 - k / 0.2) : 0);
    _emoji(c, e, Offset(z.width * 0.2, z.height * 0.72), 40 * sc);
    _emoji(c, e, Offset(z.width * 0.8, z.height * 0.72), 40 * (2.25 - sc));
  }

  // Dussehra: the arrow flies into Ravan, who goes up in flames.
  void _arrow(Canvas c, Size z) {
    final target = Offset(z.width * 0.72, z.height * 0.3);
    final t = _clamp01((s - 0.2) / 0.6);
    if (s < 1.0) _emoji(c, '👹', target, 80);
    if (t > 0 && t < 1) _emoji(c, '🏹', Offset(z.width * 0.1 + (target.dx - z.width * 0.1) * t, z.height * 0.55 - (z.height * 0.25) * t), 40, angle: -0.5);
    if (s >= 0.8) {
      final b = s - 0.8;
      c.drawCircle(target, 60 + 30 * sin(s * 10), Paint()..color = const Color(0xFFF97316).withAlpha((160 * (1 - _clamp01(b / 2.2))).round())..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30));
      _emoji(c, '🔥', target, 90 * (1 + 0.1 * sin(s * 14)), opacity: 1 - _clamp01((b - 1.6) / 0.6));
    }
  }

  // Sankranti: kites float on strings; one gets cut and falls.
  void _kites(Canvas c, Size z) {
    final spots = [const Offset(0.18, 0.18), const Offset(0.62, 0.12), const Offset(0.4, 0.3), const Offset(0.82, 0.32)];
    for (var i = 0; i < spots.length; i++) {
      var p = Offset(spots[i].dx * z.width + sin(s * 1.3 + i) * 14, spots[i].dy * z.height + cos(s * 1.1 + i) * 8);
      if (lite) p = Offset(spots[i].dx * z.width + sin(s + i) * 6, (0.25 + spots[i].dy) * z.height);
      var ang = sin(s * 2 + i) * 0.2;
      final cut = !lite && i == 1 && s > 1.8;
      if (cut) {
        final b = s - 1.8;
        p += Offset(40 * b, 220 * b * b);
        ang += b * 4;
      } else {
        c.drawLine(p + const Offset(0, 12), Offset(z.width / 2, z.height), Paint()..color = Colors.white.withAlpha(150)..strokeWidth = 0.8);
      }
      _emoji(c, '🪁', p, lite ? 18 : 40, angle: ang);
    }
    if (!lite) _emoji(c, '☀️', Offset(z.width * 0.85, z.height * 0.08), 40);
  }

  // Tiranga waving like cloth, the chakra turning.
  void _tiranga(Canvas c, Size z) {
    final top = lite ? 0.0 : z.height * 0.12;
    final hb = lite ? z.height / 3 : z.height * 0.12;
    final t = lite ? 1.0 : _ease(s / 0.7);
    const cols = [Color(0xFFFF9933), Color(0xFFFFFFFF), Color(0xFF138808)];
    for (var k = 0; k < 3; k++) {
      final path = Path();
      final w = z.width * t;
      path.moveTo(0, top + k * hb);
      for (var x = 0.0; x <= w; x += 6) {
        path.lineTo(x, top + k * hb + sin(x / 40 - s * 4) * (lite ? 2 : 8) * (x / z.width));
      }
      for (var x = w; x >= 0; x -= 6) {
        path.lineTo(x, top + (k + 1) * hb + sin(x / 40 - s * 4) * (lite ? 2 : 8) * (x / z.width));
      }
      path.close();
      c.drawPath(path, Paint()..color = cols[k]);
    }
    if (t > 0.6) {
      final cen = Offset(z.width / 2, top + hb * 1.5 + sin(z.width / 80 - s * 4) * (lite ? 1 : 4));
      final rad = hb * 0.42;
      final p = Paint()..color = const Color(0xFF0B3D91)..style = PaintingStyle.stroke..strokeWidth = lite ? 1 : 2;
      c.drawCircle(cen, rad, p);
      for (var i = 0; i < 24; i++) {
        final a = 2 * pi * i / 24 + s * 1.2;
        c.drawLine(cen, cen + Offset(cos(a), sin(a)) * rad, Paint()..color = const Color(0xFF0B3D91)..strokeWidth = lite ? 0.6 : 1);
      }
    }
  }

  // Onam: the pookalam flower carpet grows ring by ring.
  void _pookalam(Canvas c, Size z) {
    final cen = Offset(z.width / 2, z.height * (lite ? 0.5 : 0.36));
    const cols = [Color(0xFFFDE047), Color(0xFFF97316), Color(0xFFDC2626), Color(0xFFFFFFFF), Color(0xFF16A34A), Color(0xFFEAB308), Color(0xFFDB2777)];
    final rings = lite ? 4 : 7;
    for (var k = rings; k >= 1; k--) {
      final on = lite ? 1.0 : _ease((s - (rings - k) * 0.18) / 0.5);
      final rad = (lite ? 7 : 20) * k * on;
      c.drawCircle(cen, rad, Paint()..color = cols[k % cols.length]);
      final petals = 6 + k * 3;
      for (var i = 0; i < petals; i++) {
        final a = 2 * pi * i / petals + (k.isEven ? s * 0.3 : -s * 0.3);
        c.drawCircle(cen + Offset(cos(a), sin(a)) * rad, (lite ? 2 : 5) * on, Paint()..color = cols[(k + 2) % cols.length]);
      }
    }
  }

  void _sunrise(Canvas c, Size z) {
    final water = z.height * (lite ? 0.75 : 0.7);
    final t = lite ? 1.0 : _ease(s / 1.6);
    final sun = Offset(z.width / 2, water + 60 - (lite ? 40 : 200) * t);
    final rad = lite ? 20.0 : 70.0;
    c.drawCircle(sun, rad * 2, Paint()..color = const Color(0xFFFB923C).withAlpha(90)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30));
    c.drawCircle(sun, rad, Paint()..shader = const RadialGradient(colors: [Color(0xFFFEF08A), Color(0xFFF97316)]).createShader(Rect.fromCircle(center: sun, radius: rad)));
    c.drawRect(Rect.fromLTWH(0, water, z.width, z.height - water), Paint()..color = const Color(0xFF0EA5E9));
  }

  void _waves(Canvas c, Size z) {
    final water = z.height * (lite ? 0.75 : 0.7);
    for (var row = 0; row < 4; row++) {
      final y = water + 10 + row * (lite ? 6 : 22);
      for (var x = -40.0; x < z.width + 40; x += 40) {
        final xx = x + ((s * 30 * (row.isEven ? 1 : -1)) % 40);
        c.drawLine(Offset(xx, y), Offset(xx + 18, y), Paint()..color = Colors.white.withAlpha(150)..strokeWidth = 2..strokeCap = StrokeCap.round);
      }
    }
    if (!lite) {
      for (var i = 0; i < 4; i++) {
        final x = (z.width * (0.15 + i * 0.25) + s * 10) % z.width;
        _emoji(c, '🪔', Offset(x, water + 30 + (i % 2) * 30 + sin(s * 2 + i) * 3), 26);
      }
    }
  }

  void _glow(Canvas c, Size z) {
    final cen = Offset(z.width / 2, z.height * (lite ? 0.5 : 0.36));
    final k = 0.8 + 0.2 * sin(s * 2);
    c.drawCircle(cen, (lite ? 40 : 150) * k, Paint()..color = spec.accent.withAlpha(90)..maskFilter = MaskFilter.blur(BlurStyle.normal, lite ? 20 : 60));
  }

  // Shivratri: rings of light spread from the centre like Om.
  void _ripples(Canvas c, Size z) {
    final cen = Offset(z.width / 2, z.height * (lite ? 0.5 : 0.36));
    for (var i = 0; i < 4; i++) {
      final t = ((s * 0.6 + i / 4) % 1.0);
      c.drawCircle(cen, (lite ? 50 : 200) * t, Paint()..color = spec.accent.withAlpha((180 * (1 - t)).round())..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  void _wheat(Canvas c, Size z) {
    final n = (z.width / 26).ceil();
    for (var i = 0; i < n; i++) {
      _emoji(c, '🌾', Offset(i * 26.0 + 13, z.height - (lite ? 10 : 30)), lite ? 16 : 32, angle: sin(s * 2 + i * 0.5) * 0.2);
    }
  }

  @override
  bool shouldRepaint(covariant FestPainter old) => old.s != s || old.spec != spec;
}

// ---------------------------------------------------------------- splash

/// The festival's opening animation (instead of the normal splash). [preview] = GM Admin preview.
class FestivalSplash extends StatefulWidget {
  const FestivalSplash({super.key, required this.fest, required this.onDone, this.preview = false, this.kind, this.title, this.sound, this.picture});
  final Fest? fest;
  final VoidCallback onDone;
  final bool preview;
  final String? kind; // preview without a saved festival
  final String? title;
  final bool? sound;
  final ImageProvider? picture; // GM Admin preview of a picture not saved yet
  @override
  State<FestivalSplash> createState() => _FestivalSplashState();
}

class _FestivalSplashState extends State<FestivalSplash> with SingleTickerProviderStateMixin {
  static const dur = 3.4;
  late final a = AnimationController(vsync: this, duration: const Duration(milliseconds: 3400));
  late final String kind = widget.kind ?? widget.fest?.kind ?? 'diwali';
  late final FestSpec spec = festSpecs[kind] ?? festSpecs['diwali']!;

  @override
  void initState() {
    super.initState();
    final f = widget.fest;
    final playSound = widget.preview ? (widget.sound ?? true) : (f != null && Festivals.soundToday(f));
    if (playSound) FestSound.play(kind);
    a.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title ?? widget.fest?.title ?? spec.greet;
    final file = widget.fest == null ? null : Festivals.cachedImage(widget.fest!);
    final pic = widget.picture ?? (file == null ? null : FileImage(file));
    return Material(
      color: spec.bg.last,
      child: AnimatedBuilder(
        animation: a,
        builder: (context, _) {
          final s = a.value * dur;
          final hero = _ease((s - 0.15) / 0.6);
          final words = _clamp01((s - 1.3) / 0.5);
          final logo = _ease((s - 1.9) / 0.6);
          final out = _clamp01((s - 3.1) / 0.3);
          return Opacity(
            opacity: 1 - out,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: spec.bg)),
              child: Stack(fit: StackFit.expand, children: [
                CustomPaint(painter: FestPainter(spec, s)),
                Align(
                  alignment: const Alignment(0, 0.25),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // Only a picture the super admin uploaded; no picture = animation only.
                    if (pic != null) ...[
                      Transform.scale(
                        scale: 0.6 + 0.4 * hero + 0.015 * sin(s * 3) * hero,
                        child: Opacity(
                          opacity: _clamp01(hero),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.42, maxWidth: MediaQuery.of(context).size.width * 0.86),
                            child: Image(image: pic, fit: BoxFit.contain, gaplessPlayback: true),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Opacity(
                      opacity: words,
                      child: Transform.translate(
                        offset: Offset(0, 16 * (1 - words)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Text(title,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, shadows: [Shadow(color: spec.accent, blurRadius: 18)])),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Opacity(
                      opacity: _clamp01(logo),
                      child: Transform.scale(
                        scale: 0.6 + 0.4 * logo,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Logo(size: 36, body: C.orange, mark: Colors.white),
                          const SizedBox(width: 8),
                          const Text('Gym', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                          const Text('Mantra', style: TextStyle(color: C.orange, fontSize: 22, fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- around the app

/// A bottom-tab icon: the festival's own icon on festival days (the chosen tab glows and bounces).
class FestTab extends StatelessWidget {
  const FestTab(this.index, {super.key, required this.child, this.selected = false});
  final int index;
  final Widget child;
  final bool selected;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Fest?>(
        valueListenable: Festivals.active,
        builder: (_, f, __) {
          if (f == null) return child;
          final e = f.spec.tabs[index % f.spec.tabs.length];
          return selected ? _GlowTab(emoji: e, color: f.spec.accent) : Text(e, style: const TextStyle(fontSize: 21, height: 1));
        },
      );
}

class _GlowTab extends StatefulWidget {
  const _GlowTab({required this.emoji, required this.color});
  final String emoji;
  final Color color;
  @override
  State<_GlowTab> createState() => _GlowTabState();
}

class _GlowTabState extends State<_GlowTab> with SingleTickerProviderStateMixin {
  late final a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: a,
        builder: (_, __) {
          final k = sin(a.value * 2 * pi);
          return Container(
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: widget.color.withAlpha((110 + 60 * k).round()), blurRadius: 14 + 4 * k, spreadRadius: 1)]),
            child: Transform.scale(scale: 1.18 + 0.08 * k, child: Transform.rotate(angle: 0.08 * k, child: Text(widget.emoji, style: const TextStyle(fontSize: 22, height: 1)))),
          );
        },
      );
}

/// The festival card on Home (only on festival days), with a little live scene inside.
class FestBanner extends StatefulWidget {
  const FestBanner({super.key, this.padding = const EdgeInsets.only(bottom: 12)});
  final EdgeInsets padding;
  @override
  State<FestBanner> createState() => _FestBannerState();
}

class _FestBannerState extends State<FestBanner> with SingleTickerProviderStateMixin {
  late final a = AnimationController(vsync: this, duration: const Duration(seconds: 60));
  @override
  void initState() {
    super.initState();
    Festivals.active.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (Festivals.active.value != null) {
      if (!a.isAnimating) a.repeat();
    } else {
      a.stop();
    }
  }

  @override
  void dispose() {
    Festivals.active.removeListener(_sync);
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Fest?>(
        valueListenable: Festivals.active,
        builder: (_, f, __) {
          if (f == null) return const SizedBox.shrink();
          final sp = f.spec;
          return Padding(
            padding: widget.padding,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Container(
                height: 96,
                decoration: BoxDecoration(gradient: LinearGradient(colors: [sp.bg.first, sp.bg.last, sp.accent.withAlpha(220)], stops: const [0, 0.55, 1])),
                child: Stack(fit: StackFit.expand, children: [
                  AnimatedBuilder(animation: a, builder: (_, __) => CustomPaint(painter: FestPainter(sp, a.value * 60, lite: true))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      if (Festivals.cachedImage(f) != null) ...[
                        Image.file(Festivals.cachedImage(f)!, height: 72, fit: BoxFit.contain),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black54, blurRadius: 6)])),
                          if (f.sub.isNotEmpty) Text(f.sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, shadows: [Shadow(color: Colors.black54, blurRadius: 6)])),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      );
}

/// On festival days every tap throws a few festival sparkles (on top of the whole app).
class FestTapLayer extends StatefulWidget {
  const FestTapLayer({super.key, required this.child});
  final Widget child;
  @override
  State<FestTapLayer> createState() => _FestTapLayerState();
}

class _Burst {
  _Burst(this.at, this.born);
  final Offset at;
  final Duration born;
}

class _FestTapLayerState extends State<FestTapLayer> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_onTick);
  final _bursts = <_Burst>[];
  Duration _now = Duration.zero;

  void _onTick(Duration d) {
    _now = d;
    _bursts.removeWhere((b) => (d - b.born).inMilliseconds > 700);
    if (_bursts.isEmpty) _ticker.stop();
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (Festivals.active.value == null) return;
          if (!_ticker.isActive) {
            _now = Duration.zero;
            _ticker.start();
          }
          _bursts.add(_Burst(e.position, _now));
          if (_bursts.length > 6) _bursts.removeAt(0);
        },
        child: Stack(fit: StackFit.expand, children: [
          widget.child,
          if (_bursts.isNotEmpty && Festivals.active.value != null)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BurstPainter(List.of(_bursts), _now, Festivals.active.value!.spec)))),
        ]),
      );
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.bursts, this.now, this.spec);
  final List<_Burst> bursts;
  final Duration now;
  final FestSpec spec;
  @override
  void paint(Canvas c, Size z) {
    for (final b in bursts) {
      final t = _clamp01((now - b.born).inMilliseconds / 700);
      final fade = 1 - t;
      for (var k = 0; k < 10; k++) {
        final a = 2 * pi * k / 10 + (b.at.dx % 7);
        final d = 46 * _ease(t);
        final p = b.at + Offset(cos(a) * d, sin(a) * d + 30 * t * t);
        if (k % 4 == 0) {
          _emoji(c, spec.bits[k % spec.bits.length], p, 14, opacity: fade);
        } else {
          c.drawCircle(p, 2.6 * fade + 0.5, Paint()..color = (k.isEven ? spec.accent : _sparkColors[k % _sparkColors.length]).withAlpha((255 * fade).round()));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => true;
}
