import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'api.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui.dart';

/// Keeps the member's own photo on the phone, so it shows instantly
/// and is downloaded only when it changes.
class PhotoCache {
  PhotoCache._();
  static final Map<String, Uint8List> _mem = {};

  static Uint8List? get(String url) {
    final hit = _mem[url];
    if (hit != null) return hit;
    if (Prefs.getString('u:photoUrl') == url) {
      final b = Prefs.getString('u:photo');
      if (b != null) {
        try {
          return _mem[url] = base64Decode(b);
        } catch (_) {}
      }
    }
    return null;
  }

  static void put(String url, Uint8List bytes, {bool keep = true}) {
    _mem[url] = bytes;
    if (keep) {
      Prefs.setString('u:photoUrl', url);
      Prefs.setString('u:photo', base64Encode(bytes));
    }
  }

  static Future<Uint8List?> load(String url, {bool keep = true}) async {
    final hit = get(url);
    if (hit != null) return hit;
    try {
      final b = await Api.instance.bytes(url);
      put(url, b, keep: keep);
      return b;
    } catch (_) {
      return null;
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
    final circle = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: img == null ? const LinearGradient(colors: [C.orangeSoft, C.orange], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        image: img == null ? null : DecorationImage(image: MemoryImage(img), fit: BoxFit.cover),
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
