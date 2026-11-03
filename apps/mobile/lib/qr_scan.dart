import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

// QR reading without Google ML Kit: the phone's camera (Camera2) gives frames, and a pure-Dart
// ZXing reader finds the QR. ML Kit crashed on some phones ("ij3 kg3.a … null object reference").

Result? _tryDecode(LuminanceSource src) {
  final reader = QRCodeReader();
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (final s in [src, InvertedLuminanceSource(src)]) {
    for (final bin in [HybridBinarizer(s), GlobalHistogramBinarizer(s)]) {
      try {
        return reader.decode(BinaryBitmap(bin), hints: hints);
      } catch (_) {}
    }
  }
  return null;
}

/// Camera frame (Y plane) → QR text. Runs in a background isolate.
String? decodeYPlane(Map<String, Object> f) {
  final y = f['y'] as Uint8List;
  final row = f['row'] as int;
  final w = f['w'] as int;
  final h = f['h'] as int;
  // Grey pixels from the brightness (Y) plane; rows may have padding at the end.
  final px = Int32List(w * h);
  for (var j = 0; j < h; j++) {
    final o = j * row;
    final t = j * w;
    for (var i = 0; i < w; i++) {
      final v = y[o + i];
      px[t + i] = 0xFF000000 | (v << 16) | (v << 8) | v;
    }
  }
  return _tryDecode(RGBLuminanceSource(w, h, px))?.text;
}

/// A photo (jpg/png bytes) → QR text. Runs in a background isolate.
String? decodePhotoBytes(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  // Big phone photos: try a smaller copy first (faster and often better), then the full one.
  final sizes = <img.Image>[if (im.width > 1400) img.copyResize(im, width: 1200), im];
  for (final x in sizes) {
    final px = x.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List();
    final r = _tryDecode(RGBLuminanceSource(x.width, x.height, px));
    if (r != null) return r.text;
  }
  return null;
}

Future<String?> decodePhoto(Uint8List bytes) => compute(decodePhotoBytes, bytes);

/// Live camera that calls [onCode] once for each QR it reads.
class QrCamera extends StatefulWidget {
  const QrCamera({super.key, required this.onCode, required this.onError, this.torch = false, this.paused = false});
  final ValueChanged<String> onCode;
  final void Function(String code, String? detail) onError;
  final bool torch;
  final bool paused;
  @override
  State<QrCamera> createState() => QrCameraState();
}

class QrCameraState extends State<QrCamera> with WidgetsBindingObserver {
  CameraController? cam;
  bool busy = false;
  bool starting = false;
  DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastCode;
  DateTime lastCodeAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  Future<void> start() async {
    if (starting || !mounted) return;
    starting = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('noCamera', 'This phone has no camera');
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.startImageStream(_frame);
      if (widget.torch) await c.setFlashMode(FlashMode.torch).catchError((_) {});
      setState(() => cam = c);
    } on CameraException catch (e) {
      widget.onError(e.code, e.description);
    } catch (e) {
      widget.onError('cameraError', '$e');
    } finally {
      starting = false;
    }
  }

  Future<void> stop() async {
    final c = cam;
    cam = null;
    if (mounted) setState(() {});
    try {
      if (c != null && c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c?.dispose();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  void _frame(CameraImage f) {
    if (busy || widget.paused || !mounted) return;
    final now = DateTime.now();
    if (now.difference(last).inMilliseconds < 220) return; // ~4 tries a second keeps the phone cool
    last = now;
    busy = true;
    final p = f.planes.first;
    compute(decodeYPlane, <String, Object>{'y': Uint8List.fromList(p.bytes), 'row': p.bytesPerRow, 'w': f.width, 'h': f.height}).then((text) {
      if (text == null || !mounted) return;
      // Same QR again within 3 s: ignore (one scan, one check-in).
      if (text == lastCode && DateTime.now().difference(lastCodeAt).inSeconds < 3) return;
      lastCode = text;
      lastCodeAt = DateTime.now();
      widget.onCode(text);
    }).whenComplete(() => busy = false);
  }

  @override
  void didUpdateWidget(QrCamera old) {
    super.didUpdateWidget(old);
    if (old.torch != widget.torch) cam?.setFlashMode(widget.torch ? FlashMode.torch : FlashMode.off).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (cam != null) stop();
    } else if (state == AppLifecycleState.resumed) {
      if (cam == null) start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final c = cam;
    cam = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = cam;
    if (c == null || !c.value.isInitialized) return const ColoredBox(color: Color(0xFF0B0D10), child: Center(child: CircularProgressIndicator(color: Colors.white)));
    // Fill the screen with the camera picture (cropped, not stretched).
    final size = c.value.previewSize;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size == null ? 1 : size.height,
          height: size == null ? 1 : size.width,
          child: CameraPreview(c),
        ),
      ),
    );
  }
}
