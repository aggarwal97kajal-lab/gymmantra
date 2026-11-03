import 'dart:math' show Random;
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

// Trainer's PDF diet chart / workout. The member reads it only inside the app:
// no download or share button, their name is printed across every page, and
// screenshots are blocked while it is open (Android).

const _secure = MethodChannel('gymmantra/secure');

/// Opens a PDF from the server inside the app.
class PdfViewScreen extends StatefulWidget {
  const PdfViewScreen({super.key, required this.title, required this.path, this.watermark});
  final String title;
  final String path;
  final String? watermark;
  @override
  State<PdfViewScreen> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfViewScreen> {
  PdfControllerPinch? ctrl;
  String? error;
  int page = 1;
  int pages = 0;

  @override
  void initState() {
    super.initState();
    _secure.invokeMethod('on').catchError((_) => null);
    load();
  }

  Future<void> load() async {
    try {
      // Read in pieces (a big PDF in one answer is too much for the server).
      final sep = widget.path.contains('?') ? '&' : '?';
      final meta = await Api.instance.get('${widget.path}${sep}meta=1');
      final n = (meta['parts'] as num?)?.toInt() ?? 0;
      final pieces = await Future.wait([for (var i = 0; i < n; i++) Api.instance.get('${widget.path}${sep}part=$i')]);
      final b64 = pieces.map((x) => x['data'] as String).join();
      final bytes = Uint8List.fromList(base64Decode(b64));
      if (!mounted) return;
      setState(() => ctrl = PdfControllerPinch(document: PdfDocument.openData(bytes)));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  void dispose() {
    _secure.invokeMethod('off').catchError((_) => null);
    ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ctrl;
    return Scaffold(
      backgroundColor: const Color(0xFF2A2F38),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E232C),
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(color: Colors.white)),
        actions: [if (pages > 0) Center(child: Padding(padding: const EdgeInsets.only(right: 16), child: Text('$page / $pages', style: const TextStyle(color: Colors.white70))))],
      ),
      body: error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(context.t(error!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))))
          : c == null
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : Stack(children: [
                  PdfViewPinch(
                    controller: c,
                    onDocumentLoaded: (doc) => setState(() => pages = doc.pagesCount),
                    onPageChanged: (p) => setState(() => page = p),
                  ),
                  if (widget.watermark != null) IgnorePointer(child: _Watermark(text: widget.watermark!)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 14,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: const Color(0xAA000000), borderRadius: BorderRadius.circular(99)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.lock_outline_rounded, size: 14, color: Colors.white70),
                          const SizedBox(width: 6),
                          Text(context.t('Only inside the app · no download'), style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                        ]),
                      ),
                    ),
                  ),
                ]),
    );
  }
}

class _Watermark extends StatelessWidget {
  const _Watermark({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => ClipRect(
          child: Transform.rotate(
            angle: -0.5,
            child: OverflowBox(
              maxWidth: box.maxWidth * 2,
              maxHeight: box.maxHeight * 2,
              child: Wrap(
                spacing: 40,
                runSpacing: 70,
                children: [
                  for (var i = 0; i < 40; i++)
                    Text(text, style: const TextStyle(color: Color(0x1F0F172A), fontSize: 18, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Uploads keep going even when the screen that started them scrolls away or closes.
class PdfUploads extends ChangeNotifier {
  PdfUploads._();
  static final instance = PdfUploads._();
  final Map<String, PdfUploadJob> jobs = {};

  static String keyOf(String tenantId, String memberId, String kind) => '$tenantId/$memberId/$kind';

  Future<Map?> start({required String tenantId, required String memberId, required String kind, required String name, required List<int> bytes}) async {
    final key = keyOf(tenantId, memberId, kind);
    if (jobs[key]?.done == false) return null;
    final job = PdfUploadJob(name, bytes.length);
    jobs[key] = job;
    notifyListeners();
    try {
      // Small pieces, 4 at a time: fast, and each piece is light for the server.
      final b64 = base64Encode(bytes);
      const piece = 300000;
      final parts = [for (var i = 0; i < b64.length; i += piece) b64.substring(i, i + piece > b64.length ? b64.length : i + piece)];
      final uploadId = _uuid();
      var sentChars = 0;
      Future<void> sendPart(int i) async {
        for (var attempt = 1; ; attempt++) {
          try {
            await Api.instance.put('/programs/$memberId/pdf/$kind/parts/$i', {'tenantId': tenantId, 'uploadId': uploadId, 'data': parts[i]});
            break;
          } catch (e) {
            if (attempt >= 3 || (e is ApiException && e.status >= 400 && e.status < 500 && e.status != 429)) rethrow;
            await Future.delayed(Api.backoff(attempt));
          }
        }
        sentChars += parts[i].length;
        job.progress = (sentChars / b64.length * 0.97).clamp(0, 1).toDouble();
        notifyListeners();
      }
      for (var i = 0; i < parts.length; i += 4) {
        await Future.wait([for (var k = i; k < i + 4 && k < parts.length; k++) sendPart(k)]);
      }
      final p = await Api.instance.put('/programs/$memberId/pdf/$kind', {'tenantId': tenantId, 'name': name, 'uploadId': uploadId, 'parts': parts.length, 'size': bytes.length});
      job.progress = 1;
      job.result = (p as Map)[kind == 'diet' ? 'dietPdf' : 'workoutPdf'] as Map?;
      job.done = true;
      Drip.showLater('Uploaded successfully', kind: DripKind.ok);
      return job.result;
    } catch (e) {
      job.error = e.toString();
      job.done = true;
      Drip.showLater(e.toString(), kind: DripKind.error);
      return null;
    } finally {
      notifyListeners();
      // Forget finished jobs after a moment (the screen has the new PDF by then).
      Future.delayed(const Duration(seconds: 3), () {
        if (jobs[key] == job) {
          jobs.remove(key);
          notifyListeners();
        }
      });
    }
  }
}

class PdfUploadJob {
  PdfUploadJob(this.name, this.size);
  final String name;
  final int size;
  double progress = 0;
  bool done = false;
  Map? result;
  String? error;
}

/// Trainer / owner: upload, replace or remove the PDF for one plan.
class PdfUploadBox extends StatefulWidget {
  const PdfUploadBox({super.key, required this.tenantId, required this.memberId, required this.memberName, required this.kind, required this.meta, required this.onChanged});
  final String tenantId;
  final String memberId;
  final String memberName;
  final String kind; // diet | workout
  final Map? meta;
  final ValueChanged<Map?> onChanged;
  @override
  State<PdfUploadBox> createState() => _PdfUploadBoxState();
}

class _PdfUploadBoxState extends State<PdfUploadBox> {
  bool busy = false;
  bool removed = false;
  String get key => PdfUploads.keyOf(widget.tenantId, widget.memberId, widget.kind);

  @override
  void initState() {
    super.initState();
    PdfUploads.instance.addListener(_changed);
  }

  @override
  void dispose() {
    PdfUploads.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final j = PdfUploads.instance.jobs[key];
    if (j != null && j.done && j.result != null && widget.meta?['uploadedAt'] != j.result!['uploadedAt']) widget.onChanged(j.result);
    setState(() {});
  }

  Future<void> pick() async {
    final tooBig = context.t('PDF is too big. Upload a PDF up to 2 MB');
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf'], withData: true);
      final f = r?.files.firstOrNull;
      if (f == null || f.bytes == null) return;
      if (f.bytes!.length > 2 * 1024 * 1024) {
        if (mounted) toast(context, tooBig);
        return;
      }
      setState(() => removed = false);
      final res = await PdfUploads.instance.start(tenantId: widget.tenantId, memberId: widget.memberId, kind: widget.kind, name: f.name, bytes: f.bytes!);
      if (res != null && mounted) widget.onChanged(res);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  /// Gone from the screen at once; deleted on the server in the background.
  Future<void> remove() async {
    final before = widget.meta;
    setState(() => removed = true);
    widget.onChanged(null);
    try {
      await Api.instance.delete('/programs/${widget.memberId}/pdf/${widget.kind}?tenantId=${widget.tenantId}');
    } catch (e) {
      if (mounted) {
        setState(() => removed = false);
        widget.onChanged(before);
        toastError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = removed ? null : widget.meta;
    final p = context.c;
    final job = PdfUploads.instance.jobs[key];
    final uploading = job != null && !job.done;
    final progress = uploading ? job.progress : null;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconTile(widget.kind == 'diet' ? Icons.restaurant_menu_rounded : Icons.fitness_center_rounded),
          const SizedBox(width: 10),
          Expanded(child: Text(context.t(widget.kind == 'diet' ? 'Diet chart PDF' : 'Workout PDF'), style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        if (progress != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const PdfBadge(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(job!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    Muted(progress >= 0.97 ? context.t('Saving…') : context.t('Uploading… you can scroll or leave this screen'), size: 11.5),
                  ]),
                ),
                Text('${(progress * 100).round()}%', style: TextStyle(color: p.primary, fontWeight: FontWeight.w800, fontSize: 16)),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: p.line, valueColor: AlwaysStoppedAnimation(p.primary)),
              ),
              const SizedBox(height: 6),
              Muted('${_size(job!.size * progress)} ${context.t('of')} ${_size(job.size)}', size: 11),
            ]),
          ),
        ] else if (m != null) ...[
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PdfViewScreen(title: m['name'] as String, path: '/programs/${widget.memberId}/pdf/${widget.kind}?tenantId=${widget.tenantId}'),
            )),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const PdfBadge(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    Muted('${_size(m['size'] as num?)} · ${fmtDate(m['uploadedAt'] as String?)}', size: 11.5),
                  ]),
                ),
                IconButton(onPressed: busy ? null : remove, icon: const Icon(Icons.close_rounded, size: 18)),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44), side: BorderSide(color: p.primary, width: 1.4), foregroundColor: p.primary),
            onPressed: uploading ? null : pick,
            icon: uploading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file_rounded, size: 19),
            label: Text(context.t(m == null ? 'Upload PDF' : 'Change PDF')),
          ),
        ),
        const SizedBox(height: 6),
        Muted(context.t('PDF up to 2 MB. The member reads it in the app only.'), size: 11.5),
      ]),
    );
  }
}

String _size(num? b) {
  if (b == null) return '';
  if (b < 1024 * 1024) return '${(b / 1024).round()} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

class PdfBadge extends StatelessWidget {
  const PdfBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: 34,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: C.red, borderRadius: BorderRadius.circular(6)),
        child: const Text('PDF', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
      );
}

/// Member: card that opens the trainer's PDF.
class PdfCard extends StatelessWidget {
  const PdfCard({super.key, required this.meta, required this.tenantId, required this.kind, required this.watermark});
  final Map meta;
  final String tenantId;
  final String kind;
  final String watermark;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Panel(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PdfViewScreen(title: context.t(kind == 'diet' ? 'Diet chart' : 'Workout plan'), path: '/me/program/$tenantId/pdf/$kind', watermark: watermark),
          )),
          child: Row(children: [
            const PdfBadge(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t(kind == 'diet' ? 'Diet chart (PDF)' : 'Workout plan (PDF)'), style: const TextStyle(fontWeight: FontWeight.w800)),
                Muted(context.t('From {name} · {date}', {'name': meta['uploadedBy'] ?? '', 'date': fmtDate(meta['uploadedAt'] as String?)}), size: 12),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: context.c.mut),
          ]),
        ),
      );
}

/// Random id for an upload (UUID v4 format).
String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
