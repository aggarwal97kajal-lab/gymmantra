import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../api.dart';
import '../haptics.dart';
import '../i18n.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'home.dart' show openUrl, waLink;

// Two QR codes, on purpose:
//  * Join QR (orange, with the gym code) is shared on WhatsApp; scanning it only sends a join request.
//  * Check-in QR (green, no gym code) hangs in the gym; members and trainers scan it to check in.

final gymQrProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/gym/checkin-qr'));

// ============================================================ posters

class JoinPoster extends StatelessWidget {
  const JoinPoster({super.key, required this.gym, required this.city, required this.code});
  final String gym;
  final String? city;
  final String code;
  @override
  Widget build(BuildContext context) => _Poster(
        colors: const [C.orangeSoft, C.orange, C.orangeDeep],
        top: 'Join us on GymMantra',
        gym: gym,
        sub: city,
        qr: 'gymmantra-join:$code',
        bottom: 'Scan in the GymMantra app or enter code',
        code: code,
      );
}

class CheckinPoster extends StatelessWidget {
  const CheckinPoster({super.key, required this.gym, required this.qr});
  final String gym;
  final String qr;
  @override
  Widget build(BuildContext context) => _Poster(
        colors: const [Color(0xFF34D399), Color(0xFF16A34A), Color(0xFF0E7A37)],
        top: 'CHECK-IN',
        gym: gym,
        sub: null,
        qr: qr,
        bottom: 'Members & trainers: open GymMantra → Check-in → Scan',
        code: null,
      );
}

/// Fixed-size poster (360 × 500) so the saved picture always looks the same.
class _Poster extends StatelessWidget {
  const _Poster({required this.colors, required this.top, required this.gym, required this.sub, required this.qr, required this.bottom, required this.code});
  final List<Color> colors;
  final String top;
  final String gym;
  final String? sub;
  final String qr;
  final String bottom;
  final String? code;
  @override
  Widget build(BuildContext context) => Container(
        width: 360,
        height: 500,
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(26), gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontFamily: 'Jakarta'),
          textAlign: TextAlign.center,
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Logo(size: 26, body: Colors.white, mark: C.orange),
              const SizedBox(width: 8),
              Text(top, style: TextStyle(fontWeight: FontWeight.w800, fontSize: top == 'CHECK-IN' ? 15 : 13, letterSpacing: top == 'CHECK-IN' ? 2 : 0.2)),
            ]),
            const SizedBox(height: 10),
            Text(gym, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 25, height: 1.15)),
            if (sub != null && sub!.isNotEmpty) Text(sub!, style: const TextStyle(fontSize: 13, color: Color(0xE6FFFFFF))),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: QrImageView(data: qr, size: 200, padding: EdgeInsets.zero, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0F1110)), dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0F1110))),
            ),
            const Spacer(),
            Text(bottom, style: const TextStyle(fontSize: 12.5, color: Color(0xF2FFFFFF), fontWeight: FontWeight.w600)),
            if (code != null) ...[
              const SizedBox(height: 2),
              Text(code!, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 5)),
            ],
          ]),
        ),
      );
}

/// Turns a poster on screen into a PNG.
Future<Uint8List> capturePoster(GlobalKey key) async {
  final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final img = await b.toImage(pixelRatio: 3);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}


/// The English message that goes with the join poster.
String joinMessage(Map gym) {
  final name = (gym['name'] as String?) ?? 'Our gym';
  final code = (gym['gymCode'] as String?) ?? '';
  final appUrl = Prefs.getString('appUrl');
  final place = [gym['addressLine'], gym['city']].where((x) => x != null && '$x'.isNotEmpty).join(', ');
  final phone = (gym['phone'] ?? gym['whatsappNumber']) as String?;
  return [
    '🏋️ *$name* is now on the *GymMantra* app!',
    '',
    '✅ Your membership, payments and days left — all in one app',
    '✅ Check in by scanning the gym QR',
    '✅ Trainers, diet charts and offers',
    '',
    '👉 *How to join:*',
    appUrl == null || appUrl.isEmpty ? '1. Download the GymMantra app' : '1. Download GymMantra: $appUrl',
    '2. Choose "Member" and sign up',
    '3. Enter gym code: *$code*',
    '   (or scan the QR in this image)',
    if (place.isNotEmpty || phone != null) '',
    if (place.isNotEmpty) '📍 $place',
    if (phone != null) '📞 $phone',
    '',
    'See you at the gym! 💪',
  ].join('\n');
}

Future<File> _tempPng(Uint8List bytes, String name) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$name.png');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

// ============================================================ owner: Gym QR screen

class GymQrScreen extends ConsumerStatefulWidget {
  const GymQrScreen({super.key, this.share = false});

  /// Opened from "Share on WhatsApp": share the join poster straight away.
  final bool share;
  @override
  ConsumerState<GymQrScreen> createState() => _GymQrState();
}

class _GymQrState extends ConsumerState<GymQrScreen> {
  int tab = 0;
  final joinKey = GlobalKey();
  final checkinKey = GlobalKey();
  bool busy = false;
  bool autoShared = false;

  Map get gym => {...?ref.read(gymProvider).valueOrNull as Map?, ...?ref.read(sessionProvider).myGym};

  Future<void> shareJoin() async {
    setState(() => busy = true);
    try {
      await Future.delayed(const Duration(milliseconds: 60));
      final png = await capturePoster(joinKey);
      final f = await _tempPng(png, 'gym_join_${gym['gymCode'] ?? 'qr'}');
      await Share.shareXFiles([XFile(f.path, mimeType: 'image/png')], text: joinMessage(gym));
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save(GlobalKey key, String name) async {
    setState(() => busy = true);
    final ok = context.t('Saved to your photos');
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      final png = await capturePoster(key);
      await Gal.putImageBytes(png, name: name);
      TapHaptics.buzz();
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toast(context, context.t('Could not save. Allow photos access and try again'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sharePng(GlobalKey key, String name) async {
    setState(() => busy = true);
    try {
      final png = await capturePoster(key);
      final f = await _tempPng(png, name);
      await Share.shareXFiles([XFile(f.path, mimeType: 'image/png')]);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Saves the gym's exact spot: takes several GPS readings for up to ~20 s and keeps the most
  /// accurate one (aim: within 15 m), so check-in works only inside the gym.
  Future<void> setLocation() async {
    setState(() => busy = true);
    final ok = context.t('Gym location saved');
    try {
      final first = await currentPosition(context, ask: true);
      if (first == null) return;
      var best = first;
      if (mounted) toast(context, context.t('Finding the exact spot… stay inside the gym'));
      for (var i = 0; i < 6 && best.accuracy > 12; i++) {
        try {
          final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 4)));
          if (p.accuracy < best.accuracy) best = p;
        } catch (_) {}
      }
      await Api.instance.put('/gym/location', {'lat': best.latitude, 'lng': best.longitude});
      ref.invalidate(gymQrProvider);
      if (mounted) toast(context, '$ok (±${best.accuracy.round()} m)');
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> rotate() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.t('Make a new check-in QR?')),
        content: Text(context.t('The old printed QR will stop working. Print and put up the new one.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Make new QR'))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await Api.instance.post('/gym/checkin-qr/rotate');
      ref.invalidate(gymQrProvider);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    final g = {...?ref.watch(gymProvider).valueOrNull as Map?, ...?ref.watch(sessionProvider).myGym};
    final qr = ref.watch(gymQrProvider);
    final name = (g['name'] as String?) ?? '';
    final code = (g['gymCode'] as String?) ?? '';
    if (widget.share && !autoShared && code.isNotEmpty) {
      autoShared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => shareJoin());
    }
    Widget poster(Widget p, GlobalKey key) => Center(
          child: FittedBox(
            child: RepaintBoundary(key: key, child: p),
          ),
        );
    Widget actions(List<(IconData, String, VoidCallback, Color?)> items) => Row(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: i == 0
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: items[i].$4, minimumSize: const Size.fromHeight(48), padding: const EdgeInsets.symmetric(horizontal: 8)),
                      onPressed: busy ? null : items[i].$3,
                      icon: Icon(items[i].$1, size: 18),
                      label: Text(items[i].$2, overflow: TextOverflow.ellipsis),
                    )
                  : OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), padding: const EdgeInsets.symmetric(horizontal: 8)),
                      onPressed: busy ? null : items[i].$3,
                      icon: Icon(items[i].$1, size: 18),
                      label: Text(items[i].$2, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ]);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym QR'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Seg<int>(
          value: tab,
          items: [(0, context.t('Join QR'), Icons.person_add_alt_1_rounded), (1, context.t('Check-in QR'), Icons.login_rounded)],
          onChanged: (v) => setState(() => tab = v),
        ),
        const SizedBox(height: 14),
        if (tab == 0) ...[
          poster(JoinPoster(gym: name, city: g['city'] as String?, code: code), joinKey),
          const SizedBox(height: 14),
          actions([
            (Icons.share_rounded, context.t('Share'), shareJoin, C.wa),
            (Icons.download_rounded, context.t('Download'), () => save(joinKey, 'gymmantra_join_$code'), null),
            (Icons.copy_rounded, context.t('Copy code'), () {
              Clipboard.setData(ClipboardData(text: code));
              toast(context, context.t('Gym code copied'));
            }, null),
          ]),
          const SizedBox(height: 12),
          Muted(context.t('Share this on WhatsApp or Instagram. Scanning it only sends a join request — you approve it.'), size: 12.5),
        ] else
          AsyncBody(
            value: qr,
            onRetry: () => ref.invalidate(gymQrProvider),
            builder: (d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              poster(CheckinPoster(gym: name, qr: d['text'] as String), checkinKey),
              const SizedBox(height: 14),
              actions([
                (Icons.download_rounded, context.t('Download'), () => save(checkinKey, 'gymmantra_checkin'), const Color(0xFF16A34A)),
                (Icons.print_rounded, context.t('Print'), () => sharePng(checkinKey, 'gymmantra_checkin'), null),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: C.warn.withAlpha(34), borderRadius: BorderRadius.circular(14)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lock_outline_rounded, size: 18, color: Color(0xFFB45309)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.t('Don’t share this QR — put it up inside the gym. It has no gym code, so nobody can join with it.'),
                      style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w600, fontSize: 12.5),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Panel(
                child: Row(children: [
                  IconTile(Icons.place_rounded, color: d['locationSet'] == true ? C.ok : C.warn),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d['locationSet'] == true ? context.t('Gym location set ✓') : context.t('Gym location not set'), style: const TextStyle(fontWeight: FontWeight.w800)),
                      Muted(
                        d['locationSet'] == true
                            ? context.t('Check-in works only within {m} m of the gym', {'m': d['radiusM'] ?? 20})
                            : context.t('Stand inside the gym and tap Set, so nobody can check in from home with a photo of the QR'),
                        size: 12,
                      ),
                    ]),
                  ),
                  if (owner) TextButton(onPressed: busy ? null : setLocation, child: Text(context.t(d['locationSet'] == true ? 'Update' : 'Set'))),
                ]),
              ),
              if (owner) ...[
                const SizedBox(height: 6),
                TextButton.icon(onPressed: rotate, icon: const Icon(Icons.refresh_rounded, size: 18), label: Text(context.t('Make a new check-in QR'))),
              ],
            ]),
          ),
      ]),
    );
  }
}

/// Phone location (asks for permission once). Null if the person says no or it is off.
Future<Position?> currentPosition(BuildContext context, {bool ask = true}) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (context.mounted) toast(context, 'Turn on location (GPS) and try again');
      return null;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied && ask) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      if (context.mounted) toast(context, 'Allow location for GymMantra to check in');
      return null;
    }
    return await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)));
  } catch (_) {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }
}

// ============================================================ member / trainer: scan to check in

class ScanCheckinScreen extends ConsumerStatefulWidget {
  const ScanCheckinScreen({super.key, this.standalone = false});

  /// Opened on its own (trainer), not as a bottom tab.
  final bool standalone;
  @override
  ConsumerState<ScanCheckinScreen> createState() => _ScanState();
}

class _ScanState extends ConsumerState<ScanCheckinScreen> with WidgetsBindingObserver {
  // Started by hand (not autoStart) so it can be restarted after the camera permission
  // is given, or when the person comes back from phone settings.
  MobileScannerController? cam = MobileScannerController(autoStart: false, detectionSpeed: DetectionSpeed.noDuplicates, formats: const [BarcodeFormat.qrCode]);
  bool working = false;
  Map? result;
  String? error;
  bool torch = false;
  MobileScannerErrorCode? camError;
  bool starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => startCam());
  }

  Future<void> startCam() async {
    if (starting || cam == null || result != null) return;
    starting = true;
    try {
      await cam!.start();
      if (mounted) setState(() => camError = null);
    } on MobileScannerException catch (e) {
      if (e.errorCode == MobileScannerErrorCode.controllerAlreadyInitialized) {
        if (mounted) setState(() => camError = null);
      } else if (mounted) {
        setState(() => camError = e.errorCode);
      }
    } catch (_) {
      if (mounted) setState(() => camError = MobileScannerErrorCode.genericError);
    } finally {
      starting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (cam == null) return;
    if (state == AppLifecycleState.resumed) {
      if (result == null) startCam();
    } else if (state == AppLifecycleState.paused) {
      cam!.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cam?.dispose();
    super.dispose();
  }

  Future<void> onCode(String code) async {
    if (working || result != null || error != null) return;
    setState(() => working = true);
    TapHaptics.buzz();
    try {
      if (code.startsWith('gymmantra-join:')) {
        throw ApiException(400, 'This is the gym’s join QR. To check in, scan the green check-in QR inside the gym');
      }
      if (!code.startsWith('gymmantra-checkin:')) throw ApiException(400, 'This is not a GymMantra check-in QR');
      final pos = await currentPosition(context);
      final r = await Api.instance.post('/me/checkin', {
        'code': code,
        if (pos != null) 'lat': pos.latitude,
        if (pos != null) 'lng': pos.longitude,
        if (pos != null) 'accuracy': pos.accuracy,
      });
      HapticFeedback.mediumImpact();
      await cam?.stop();
      ref.invalidate(gymsProvider);
      if (mounted) setState(() => result = r as Map);
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void again() {
    setState(() {
      result = null;
      error = null;
    });
    startCam();
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r != null) return _ResultView(r: r, onDone: widget.standalone ? () => context.pop() : again, standalone: widget.standalone);
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D10),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(context.t('Scan check-in QR'), style: const TextStyle(color: Colors.white)),
        automaticallyImplyLeading: widget.standalone,
      ),
      body: Stack(children: [
        Positioned.fill(
          child: MobileScanner(
            controller: cam,
            onDetect: (cap) {
              final v = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
              if (v != null) onCode(v);
            },
            errorBuilder: (context, e, _) => _CamProblem(code: e.errorCode, onRetry: startCam),
          ),
        ),
        if (camError != null) Positioned.fill(child: _CamProblem(code: camError!, onRetry: startCam)),
        // Frame
        if (camError == null)
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(border: Border.all(color: C.orange, width: 4), borderRadius: BorderRadius.circular(24)),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Column(children: [
            if (working) const Padding(padding: EdgeInsets.only(bottom: 14), child: CircularProgressIndicator(color: Colors.white)),
            if (error != null)
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: const Color(0xEEB91C1C), borderRadius: BorderRadius.circular(16)),
                child: Column(children: [
                  Text(context.t(error!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFFB91C1C)), onPressed: again, child: Text(context.t('Try again'))),
                ]),
              )
            else ...[
              Text(context.t('Point the camera at the check-in QR in your gym'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              Text(context.t('You are checked in as soon as it scans'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _RoundBtn(
                icon: torch ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                label: context.t('Torch'),
                onTap: () {
                  cam?.toggleTorch();
                  setState(() => torch = !torch);
                },
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Camera could not start: ask for permission (or open settings if it was refused for good).
class _CamProblem extends StatelessWidget {
  const _CamProblem({required this.code, required this.onRetry});
  final MobileScannerErrorCode code;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final perm = code == MobileScannerErrorCode.permissionDenied;
    return Container(
      color: const Color(0xFF0B0D10),
      padding: const EdgeInsets.all(28),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(color: C.orange.withAlpha(46), shape: BoxShape.circle),
          child: const Icon(Icons.photo_camera_rounded, color: C.orange, size: 38),
        ),
        const SizedBox(height: 16),
        Text(
          perm ? context.t('Camera permission needed') : context.t('Camera did not start'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          perm ? context.t('Allow GymMantra to use the camera to scan the QR') : context.t('Close other apps using the camera and try again'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
          onPressed: onRetry,
          child: Text(perm ? context.t('Allow camera') : context.t('Try again')),
        ),
        if (perm) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Geolocator.openAppSettings(),
            child: Text(context.t('Open phone settings'), style: const TextStyle(color: Color(0xCCFFFFFF))),
          ),
        ],
      ]),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: const Color(0x26FFFFFF),
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 54, height: 54, child: Icon(icon, color: Colors.white))),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]);
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.r, required this.onDone, required this.standalone});
  final Map r;
  final VoidCallback onDone;
  final bool standalone;
  @override
  Widget build(BuildContext context) {
    final blocked = r['result'] == 'BLOCKED';
    final dup = r['duplicate'] == true;
    final gym = (r['gym'] as Map?) ?? {};
    final at = DateTime.tryParse((r['at'] as String?) ?? '')?.toLocal();
    final time = at == null ? '' : TimeOfDay.fromDateTime(at).format(context);
    final color = blocked ? C.red : C.ok;
    final wa = (gym['whatsappNumber'] ?? gym['phone']) as String?;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Check-in')), automaticallyImplyLeading: standalone),
      body: ListView(padding: const EdgeInsets.fromLTRB(22, 30, 22, 24), children: [
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(color: color.withAlpha(36), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(blocked ? Icons.block_rounded : Icons.check_rounded, color: Colors.white, size: 46),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          blocked ? context.t('Entry stopped') : dup ? context.t('Already checked in today') : context.t('Checked in!'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Muted('${gym['name'] ?? ''}${time.isEmpty ? '' : ' · $time'}', align: TextAlign.center),
        if (blocked && r['reason'] != null) ...[
          const SizedBox(height: 6),
          Text(context.t(r['reason'] as String), textAlign: TextAlign.center, style: const TextStyle(color: C.red, fontWeight: FontWeight.w700)),
          Muted(context.t('Please talk to the front desk.'), align: TextAlign.center),
        ],
        const SizedBox(height: 22),
        if (!blocked)
          Panel(
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _Num('${r['visitsThisMonth'] ?? 0}', context.t('This month')),
              if (r['daysLeft'] != null) _Num('${r['daysLeft']}', context.t('Days left')),
              if (r['kind'] == 'TRAINER') _Num('✓', context.t('Trainer')),
            ]),
          ),
        if (blocked && wa != null) ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: C.wa, minimumSize: const Size.fromHeight(50)),
            onPressed: () => openUrl(waLink(wa, 'Hi, my check-in was stopped. ${r['reason'] ?? ''}')),
            icon: const Icon(Icons.chat_rounded),
            label: Text(context.t('WhatsApp the gym')),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: onDone, child: Text(context.t(standalone ? 'Done' : 'Scan again'))),
        const SizedBox(height: 8),
        Muted(context.t('Scanning again on the same day does not count again.'), align: TextAlign.center, size: 12),
      ]),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num(this.v, this.l);
  final String v;
  final String l;
  @override
  Widget build(BuildContext context) => Column(children: [Text(v, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), Muted(l, size: 12)]);
}
