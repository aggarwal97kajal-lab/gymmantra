import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureType;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'i18n.dart';
import 'prefs.dart';

/// "Drip" toasts: a small black pill drips out of the phone's front camera,
/// grows into a message (and, when there is more to say, into a card with a
/// button), then goes back up into the camera.
///
/// * ok (green tick), error (red cross, shakes and buzzes), info (orange i).
/// * Several messages stack behind each other ("+2 more"); tap the stack to
///   fan them out, tap outside to fold them back.
/// * Info messages are "single": a new one swallows the old one.
/// * Swipe up to close.
enum DripKind { ok, error, info }

const _ink = Color(0xFF101318);
const _sub = Color(0xFFB8C0CC);
Color _tint(DripKind k) => switch (k) {
      DripKind.ok => const Color(0xFF22C55E),
      DripKind.error => const Color(0xFFEF4444),
      DripKind.info => const Color(0xFFFF7A45),
    };
IconData _icon(DripKind k) => switch (k) {
      DripKind.ok => Icons.check_rounded,
      DripKind.error => Icons.close_rounded,
      DripKind.info => Icons.info_outline_rounded,
    };

/// Guesses the kind from the words when the caller did not say.
DripKind guessKind(String msg) {
  final m = msg.toLowerCase();
  if (RegExp(r"could not|couldn't|cannot|can't|wrong|fail|error|invalid|must |not valid|not available|went wrong|no internet|try again|allow |turn on|too big|not allowed|already|only the|enter ").hasMatch(m)) {
    return DripKind.error;
  }
  if (RegExp(r'^(press|showing|finding|tap )|coming soon|stay inside').hasMatch(m)) return DripKind.info;
  return DripKind.ok;
}

class DripItem {
  DripItem({required this.title, required this.kind, this.detail, this.action, this.onAction, this.single = false});
  final String title;
  final DripKind kind;
  final String? detail;
  final String? action;
  final VoidCallback? onAction;
  final bool single;
  final DateTime at = DateTime.now();
  final key = UniqueKey();
  bool leaving = false;
  Timer? timer;
  Duration get life => Duration(milliseconds: detail != null || action != null ? 4500 : (kind == DripKind.error ? 3400 : 2400));
}

class Drip {
  Drip._();
  static final items = ValueNotifier<List<DripItem>>([]);
  static final fanned = ValueNotifier<bool>(false);
  static OverlayEntry? _entry;

  static OverlayState? _last;

  static void show(BuildContext context, String title, {DripKind? kind, String? detail, String? action, VoidCallback? onAction, bool? single}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ?? _last;
    if (overlay == null) return;
    showOn(overlay, title, kind: kind, detail: detail, action: action, onAction: onAction, single: single);
  }

  /// For messages that arrive after the screen that asked has closed (saving in the background).
  static void showLater(String title, {DripKind? kind}) {
    final o = _last;
    if (o != null && o.mounted) showOn(o, title, kind: kind);
  }

  static void showOn(OverlayState overlay, String title, {DripKind? kind, String? detail, String? action, VoidCallback? onAction, bool? single}) {
    _last = overlay;
    if (_entry == null || !_entry!.mounted) {
      _entry = OverlayEntry(builder: (_) => const _DripHost());
      overlay.insert(_entry!);
    }
    final k = kind ?? guessKind(title);
    final item = DripItem(title: title, kind: k, detail: detail, action: action, onAction: onAction, single: single ?? k == DripKind.info);
    var list = [...items.value.where((x) => !x.leaving)];
    if (item.single) {
      for (final x in list) {
        x.timer?.cancel();
      }
      list = [];
    }
    // The same text again just restarts its timer.
    final same = list.where((x) => x.title == title && x.detail == detail).toList();
    for (final x in same) {
      x.timer?.cancel();
      list.remove(x);
    }
    list = [item, ...list].take(4).toList();
    items.value = list;
    _arm(item);
    if (AppSettings.instance.haptics) {
      k == DripKind.error ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact();
    }
  }

  static void _arm(DripItem x) {
    x.timer?.cancel();
    x.timer = Timer(x.life, () {
      if (fanned.value) {
        _arm(x); // wait while the person is reading the fanned-out list
      } else {
        dismiss(x);
      }
    });
  }

  static void dismiss(DripItem x) {
    x.timer?.cancel();
    if (x.leaving) return;
    x.leaving = true;
    items.value = [...items.value];
    Timer(const Duration(milliseconds: 380), () {
      items.value = items.value.where((y) => y != x).toList();
      if (items.value.isEmpty) fanned.value = false;
    });
  }

  static void dismissAll() {
    for (final x in [...items.value]) {
      dismiss(x);
    }
  }
}

/// Where the front camera is: the cutout Android reports, else top centre.
Offset _cameraOf(MediaQueryData mq) {
  for (final f in mq.displayFeatures) {
    if (f.type == DisplayFeatureType.cutout && f.bounds.top < 120) return f.bounds.center;
  }
  final top = mq.viewPadding.top;
  return Offset(mq.size.width / 2, top > 0 ? top / 2 : 14);
}

class _DripHost extends StatelessWidget {
  const _DripHost();
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cam = _cameraOf(mq);
    // Cards stay near the middle even when the camera sits in a corner.
    final cx = cam.dx.clamp(160.0, math.max(160.0, mq.size.width - 160));
    return ValueListenableBuilder<bool>(
      valueListenable: Drip.fanned,
      builder: (_, fan, __) => ValueListenableBuilder<List<DripItem>>(
        valueListenable: Drip.items,
        builder: (_, list, __) {
          if (list.isEmpty) return const SizedBox.shrink();
          final live = list.where((x) => !x.leaving).length;
          return Material(type: MaterialType.transparency, child: Stack(children: [
            if (fan)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Drip.fanned.value = false,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 220),
                    builder: (_, t, __) => ColoredBox(color: Colors.black.withValues(alpha: 0.55 * t)),
                  ),
                ),
              ),
            if (fan)
              Positioned(
                top: mq.viewPadding.top + 6,
                left: 12,
                right: 12,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final x in list.where((x) => !x.leaving))
                      Padding(
                        key: x.key,
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Swipe(item: x, child: _CardBody(item: x, wide: true)),
                      ),
                    if (live > 1)
                      TextButton(
                        onPressed: Drip.dismissAll,
                        child: Text(translate(AppLang.current, 'Clear all'), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                ),
              )
            else
              for (var i = list.length - 1; i >= 0; i--)
                _Drop(
                  key: list[i].key,
                  item: list[i],
                  depth: list.take(i).where((x) => !x.leaving).length,
                  more: i == 0 ? live - 1 : 0,
                  camera: Offset(cam.dx, cam.dy),
                  centerX: cx.toDouble(),
                  top: mq.viewPadding.top + 6,
                  maxWidth: mq.size.width - 24,
                ),
          ]));
        },
      ),
    );
  }
}

/// One message: drips from the camera, bounces into place, can shake.
class _Drop extends StatefulWidget {
  const _Drop({super.key, required this.item, required this.depth, required this.more, required this.camera, required this.centerX, required this.top, required this.maxWidth});
  final DripItem item;
  final int depth; // 0 = front
  final int more;
  final Offset camera;
  final double centerX;
  final double top;
  final double maxWidth;
  @override
  State<_Drop> createState() => _DropState();
}

class _DropState extends State<_Drop> with TickerProviderStateMixin {
  late final AnimationController drop = AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
  late final AnimationController shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final AnimationController open = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  bool get hasCard => widget.item.detail != null || widget.item.action != null;

  @override
  void initState() {
    super.initState();
    drop.forward().whenComplete(() {
      if (!mounted) return;
      if (widget.item.kind == DripKind.error) shake.forward(from: 0);
      if (hasCard) Future.delayed(const Duration(milliseconds: 120), () => mounted ? open.forward() : null);
    });
  }

  @override
  void didUpdateWidget(covariant _Drop old) {
    super.didUpdateWidget(old);
    if (widget.item.leaving && drop.status != AnimationStatus.reverse && drop.value > 0) {
      open.reverse();
      drop.animateBack(0, duration: const Duration(milliseconds: 360), curve: Curves.easeInCubic);
    }
  }

  @override
  void dispose() {
    drop.dispose();
    shake.dispose();
    open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([drop, shake, open]),
      builder: (context, _) {
        final t = drop.value;
        final leaving = widget.item.leaving;
        // Position: from the camera to just under the status bar (with a bounce on the way in).
        final yIn = leaving ? Curves.easeIn.transform(t) : Curves.easeOutBack.transform(t.clamp(0.0, 1.0));
        final y = _lerp(widget.camera.dy - 8, widget.top, yIn) + widget.depth * -5.0;
        // Shape: a dot that stretches like a drop, then widens into the pill.
        final wT = leaving ? Curves.easeIn.transform(t) : Curves.elasticOut.transform(((t - 0.18) / 0.82).clamp(0.0, 1.0));
        final grow = wT.clamp(0.0, 1.2);
        final contentOpacity = ((t - 0.45) / 0.4).clamp(0.0, 1.0);
        final dx = math.sin(shake.value * math.pi * 6) * 9 * (1 - shake.value);
        final scale = 1 - widget.depth * 0.06;
        final dim = widget.depth == 0 ? 1.0 : (widget.depth == 1 ? 0.75 : 0.5);
        final camX = widget.camera.dx;
        final x = _lerp(camX, widget.centerX, Curves.easeOut.transform(t.clamp(0.0, 1.0)));
        return Positioned(
          top: y,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: widget.depth > 0 || leaving,
            child: Transform.translate(
              offset: Offset(x - MediaQuery.of(context).size.width / 2 + dx, 0),
              child: Center(
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topCenter,
                  child: Opacity(
                    opacity: (dim * (leaving ? t.clamp(0.0, 1.0) : 1.0)).clamp(0.0, 1.0),
                    child: _Swipe(
                      item: widget.item,
                      onTapStack: widget.more > 0 ? () => Drip.fanned.value = true : null,
                      child: _Blob(
                        grow: grow,
                        stretch: t < 0.3 ? t / 0.3 : 1.0,
                        maxWidth: widget.maxWidth,
                        contentOpacity: contentOpacity,
                        child: hasCard
                            ? _CardBody(item: widget.item, wide: false, more: widget.more, reveal: CurvedAnimation(parent: open, curve: Curves.easeOutCubic))
                            : _PillBody(item: widget.item, more: widget.more),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// The black shape: starts as a camera-sized dot and stretches to its content.
class _Blob extends StatelessWidget {
  const _Blob({required this.grow, required this.stretch, required this.maxWidth, required this.contentOpacity, required this.child});
  final double grow; // 0 dot → 1 full
  final double stretch;
  final double maxWidth;
  final double contentOpacity;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (grow <= 0.02) {
      // the drop: a little taller than wide while it falls
      return Container(width: 16, height: 16 + 10 * stretch, decoration: const BoxDecoration(color: _ink, borderRadius: BorderRadius.vertical(top: Radius.circular(8), bottom: Radius.circular(10))));
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Align(
          widthFactor: grow.clamp(0.06, 1.2),
          heightFactor: (0.45 + 0.55 * grow).clamp(0.3, 1.1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(22),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 10))],
            ),
            child: Opacity(opacity: contentOpacity, child: child),
          ),
        ),
      ),
    );
  }
}

Widget _badge(DripKind k, [double s = 22]) => Container(
      width: s,
      height: s,
      decoration: BoxDecoration(color: _tint(k).withValues(alpha: 0.18), shape: BoxShape.circle),
      child: Icon(_icon(k), size: s - 8, color: _tint(k)),
    );

const _font = TextStyle(fontFamily: 'Jakarta', decoration: TextDecoration.none);

class _PillBody extends StatelessWidget {
  const _PillBody({required this.item, this.more = 0});
  final DripItem item;
  final int more;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(7, 6, 14, 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _badge(item.kind),
          const SizedBox(width: 8),
          Flexible(
            child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _font.copyWith(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.25)),
          ),
          if (more > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99)),
              child: Text('+$more', style: _font.copyWith(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
      );
}

class _CardBody extends StatelessWidget {
  const _CardBody({required this.item, required this.wide, this.more = 0, this.reveal});
  final DripItem item;
  final bool wide;
  final int more;
  /// Opens the details and button after the pill has landed (null = open).
  final Animation<double>? reveal;
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width - 28;
    final time = TimeOfDay.fromDateTime(item.at).format(context);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _badge(item.kind, 24),
          const SizedBox(width: 9),
          Expanded(child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _font.copyWith(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800))),
          if (more > 0)
            Padding(padding: const EdgeInsets.only(right: 6), child: Text('+$more', style: _font.copyWith(color: _sub, fontSize: 11, fontWeight: FontWeight.w800))),
          Text(time, style: _font.copyWith(color: const Color(0xFF8B95A5), fontSize: 11)),
        ]),
        Builder(builder: (_) {
          final extraPart = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (item.detail != null)
              Padding(
                padding: const EdgeInsets.only(left: 33, top: 5),
                child: Text(item.detail!, style: _font.copyWith(color: _sub, fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w500)),
              ),
            if (item.action != null) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 38,
                child: TextButton(
                  style: TextButton.styleFrom(backgroundColor: _tint(item.kind).withValues(alpha: 0.16), foregroundColor: _tint(item.kind), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: () {
                    Drip.dismiss(item);
                    Drip.fanned.value = false;
                    item.onAction?.call();
                  },
                  child: Text(item.action!, style: _font.copyWith(fontWeight: FontWeight.w800, fontSize: 13.5, color: _tint(item.kind))),
                ),
              ),
            ],
          ]);
          final r = reveal;
          return r == null ? extraPart : SizeTransition(sizeFactor: r, axisAlignment: -1, child: extraPart);
        }),
      ]),
    );
    if (!wide) return SizedBox(width: w, child: body);
    return DecoratedBox(
      decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(22), boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 10))]),
      child: body,
    );
  }
}

/// Swipe up closes it; a tap on a stack fans it out; a tap on a single toast closes it.
class _Swipe extends StatefulWidget {
  const _Swipe({required this.item, required this.child, this.onTapStack});
  final DripItem item;
  final Widget child;
  final VoidCallback? onTapStack;
  @override
  State<_Swipe> createState() => _SwipeState();
}

class _SwipeState extends State<_Swipe> {
  double dy = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTapStack ?? (widget.item.action == null ? () => Drip.dismiss(widget.item) : null),
        onVerticalDragUpdate: (d) => setState(() => dy = math.min(0, dy + d.delta.dy)),
        onVerticalDragEnd: (d) {
          if (dy < -18 || (d.primaryVelocity ?? 0) < -300) {
            Drip.dismiss(widget.item);
          }
          setState(() => dy = 0);
        },
        child: Transform.translate(offset: Offset(0, dy), child: widget.child),
      );
}
