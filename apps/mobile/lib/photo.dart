import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'theme.dart';
import 'ui.dart';

/// Every profile photo is saved on the phone once and shown from there after that,
/// so lists and profiles never wait for the server. Photo links carry a version
/// (`?v=…`), so a changed photo has a new link and is downloaded again.
class PhotoCache {
  PhotoCache._();
  static final Map<String, Uint8List> _mem = {};
  static final Map<String, Future<Uint8List?>> _loading = {};
  static Directory? _dir;

  /// Call once at start-up (fast; just finds the folder).
  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/photos');
      if (!d.existsSync()) d.createSync(recursive: true);
      _dir = d;
    } catch (_) {}
  }

  static String _key(String url) {
    var h = 0x811c9dc5;
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return '${h.toRadixString(16)}_${url.length}';
  }

  static File? _file(String url) => _dir == null ? null : File('${_dir!.path}/${_key(url)}');

  /// From memory or the phone's storage; null if never downloaded.
  static Uint8List? get(String url) {
    final hit = _mem[url];
    if (hit != null) return hit;
    final f = _file(url);
    if (f != null && f.existsSync()) {
      try {
        final b = f.readAsBytesSync();
        if (b.isNotEmpty) return _mem[url] = b;
      } catch (_) {}
    }
    return null;
  }

  static void put(String url, Uint8List bytes, {bool keep = true}) {
    _mem[url] = bytes;
    try {
      _file(url)?.writeAsBytesSync(bytes, flush: false);
    } catch (_) {}
  }

  static Future<Uint8List?> load(String url, {bool keep = true}) {
    final hit = get(url);
    if (hit != null) return Future.value(hit);
    return _loading[url] ??= () async {
      try {
        final b = await Api.instance.bytes(url);
        put(url, b);
        return b;
      } catch (_) {
        return null;
      } finally {
        _loading.remove(url);
      }
    }();
  }

  /// Downloads photos in the background (used after a list loads).
  static void warm(Iterable<String?> urls) {
    for (final u in urls) {
      if (u != null && u.isNotEmpty && get(u) == null) load(u);
    }
  }
}

class Avatar extends StatefulWidget {
  const Avatar({super.key, required this.name, this.url, this.size = 88, this.local, this.ring = false});
  final String name;
  final String? url;
  final double size;

  /// A photo just picked on this phone, shown while it uploads.
  final Uint8List? local;
  final bool ring;
  @override
  State<Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<Avatar> {
  Uint8List? bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(Avatar old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  void _load() {
    final url = widget.url;
    if (url == null) {
      bytes = null;
      return;
    }
    bytes = PhotoCache.get(url);
    if (bytes == null) {
      PhotoCache.load(url).then((b) {
        if (mounted && widget.url == url) setState(() => bytes = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = widget.local ?? (widget.url == null ? null : bytes);
    final s = widget.size;
    final px = (s * MediaQuery.devicePixelRatioOf(context)).round();
    final circle = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: img == null ? const LinearGradient(colors: [C.orangeSoft, C.orange], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        // Decode at the size shown, not the full photo: much faster in long lists.
        image: img == null ? null : DecorationImage(image: ResizeImage(MemoryImage(img), width: (px * 1.6).round(), policy: ResizeImagePolicy.fit), fit: BoxFit.cover),
      ),
      alignment: Alignment.center,
      child: img == null ? Text(initialsOf(widget.name), style: TextStyle(fontSize: s * 0.36, fontWeight: FontWeight.w800, color: Colors.white)) : null,
    );
    if (!widget.ring) return circle;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.orange, width: 2.5)),
      child: circle,
    );
  }
}
