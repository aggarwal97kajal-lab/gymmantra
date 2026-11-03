import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

// Shared report pieces: date range (7 / 30 / 90 / Custom), small charts, and real downloads.

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class ReportRange {
  const ReportRange._(this.days, this.from, this.to);
  factory ReportRange.days(int d) => ReportRange._(d, null, null);
  factory ReportRange.custom(DateTime from, DateTime to) => ReportRange._(null, from, to);
  final int? days;
  final DateTime? from;
  final DateTime? to;
  bool get custom => days == null;
  String get query => custom ? 'from=${_ymd(from!)}&to=${_ymd(to!)}' : 'days=$days';
  @override
  bool operator ==(Object o) => o is ReportRange && o.query == query;
  @override
  int get hashCode => query.hashCode;
}

/// 7 days · 30 days · 90 days · Custom (pick From and To).
class RangePicker extends StatelessWidget {
  const RangePicker({super.key, required this.value, required this.onChanged, this.accent, this.presets = const [7, 30, 90]});
  final ReportRange value;
  final ValueChanged<ReportRange> onChanged;
  final Color? accent;
  final List<int> presets;

  Future<void> pickCustom(BuildContext context) async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: value.custom ? DateTimeRange(start: value.from!, end: value.to!) : DateTimeRange(start: now.subtract(const Duration(days: 14)), end: now),
      helpText: context.t('Custom dates'),
      saveText: context.t('Show report'),
      fieldStartLabelText: context.t('From'),
      fieldEndLabelText: context.t('To'),
    );
    if (r == null) return;
    if (r.end.difference(r.start).inDays > 365) {
      if (context.mounted) toast(context, context.t('Choose up to 1 year'), kind: DripKind.error);
      return;
    }
    onChanged(ReportRange.custom(r.start, r.end));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final a = accent ?? p.primary;
    Widget item(String label, bool on, VoidCallback tap) => Expanded(
          child: GestureDetector(
            onTap: tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(color: on ? p.surf : Colors.transparent, borderRadius: BorderRadius.circular(10), boxShadow: on ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))] : null),
              alignment: Alignment.center,
              child: Text(label, maxLines: 1, style: TextStyle(fontWeight: on ? FontWeight.w800 : FontWeight.w600, fontSize: 13, color: on ? a : p.mut)),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          for (final d in presets) item(d == 365 ? context.t('This year') : context.t('{n} days', {'n': d}), value.days == d, () => onChanged(ReportRange.days(d))),
          item(context.t('Custom'), value.custom, () => pickCustom(context)),
        ]),
      ),
      if (value.custom)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: InkWell(
            onTap: () => pickCustom(context),
            child: Row(children: [
              Icon(Icons.date_range_rounded, size: 16, color: a),
              const SizedBox(width: 6),
              Text('${fmtDate(_ymd(value.from!))} – ${fmtDate(_ymd(value.to!))}', style: TextStyle(fontWeight: FontWeight.w700, color: a)),
              const SizedBox(width: 6),
              Text(context.t('Change'), style: TextStyle(color: p.mut, fontSize: 12.5)),
            ]),
          ),
        ),
    ]);
  }
}

String shortRupees(num n) {
  if (n >= 10000000) return '₹${(n / 10000000).toStringAsFixed(1)}Cr';
  if (n >= 100000) return '₹${(n / 100000).toStringAsFixed(1)}L';
  if (n >= 1000) return '₹${(n / 1000).toStringAsFixed(1)}k';
  return '₹$n';
}

class StatBox extends StatelessWidget {
  const StatBox({super.key, required this.value, required this.label, required this.color});
  final String value;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FittedBox(child: Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w800))),
          Muted(label, size: 12),
        ]),
      );
}

/// Adds up daily numbers into weeks (last bar = latest week).
List<double> weekly(List<double> daily) {
  final out = <double>[];
  for (var i = daily.length; i > 0; i -= 7) {
    out.insert(0, daily.sublist(math.max(0, i - 7), i).fold(0.0, (a, b) => a + b));
  }
  return out.length > 12 ? out.sublist(out.length - 12) : out;
}

class LineChartMini extends StatelessWidget {
  const LineChartMini({super.key, required this.values, required this.color});
  final List<double> values;
  final Color color;
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _LinePainter(values, color), child: const SizedBox.expand());
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.v, this.color);
  final List<double> v;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    if (v.isEmpty) return;
    final mx = v.reduce(math.max);
    final top = mx <= 0 ? 1.0 : mx;
    final dx = v.length == 1 ? 0.0 : s.width / (v.length - 1);
    Offset pt(int i) => Offset(i * dx, s.height - (v[i] / top) * (s.height - 6) - 3);
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(line)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withAlpha(30));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.v != v;
}

class BarsMini extends StatelessWidget {
  const BarsMini({super.key, required this.values, required this.color});
  final List<double> values;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final mx = values.isEmpty ? 1.0 : math.max(1.0, values.reduce(math.max));
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 0; i < values.length; i++)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (values[i] > 0) Text(values[i].toStringAsFixed(0), style: TextStyle(fontSize: 10, color: context.c.mut)),
              Container(
                height: math.max(3, 84 * values[i] / mx),
                decoration: BoxDecoration(color: color.withAlpha(110 + (145 * (i + 1) ~/ math.max(1, values.length))), borderRadius: BorderRadius.circular(5)),
              ),
            ]),
          ),
        ),
    ]);
  }
}

const _donutColors = [C.indigo, C.ok, C.warn, Color(0xFF94A3B8), C.red, C.blue, C.orange];

class DonutWithLegend extends StatelessWidget {
  const DonutWithLegend({super.key, required this.items});
  final List<(String, double)> items;
  @override
  Widget build(BuildContext context) {
    final total = items.fold(0.0, (a, b) => a + b.$2);
    return Row(children: [
      SizedBox(width: 100, height: 100, child: CustomPaint(painter: _DonutPainter([for (final x in items) x.$2], total))),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: _donutColors[i % _donutColors.length], borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 8),
                Expanded(child: Text('${items[i].$1} · ${items[i].$2.toStringAsFixed(0)}', style: const TextStyle(fontSize: 13))),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.v, this.total);
  final List<double> v;
  final double total;
  @override
  void paint(Canvas canvas, Size s) {
    final rect = Rect.fromLTWH(10, 10, s.width - 20, s.height - 20);
    if (total <= 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, Paint()..color = const Color(0x22000000)..style = PaintingStyle.stroke..strokeWidth = 18);
      return;
    }
    var start = -math.pi / 2;
    for (var i = 0; i < v.length; i++) {
      final sweep = v[i] / total * math.pi * 2;
      canvas.drawArc(rect, start, sweep, false, Paint()..color = _donutColors[i % _donutColors.length]..style = PaintingStyle.stroke..strokeWidth = 18);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter o) => true;
}

// ---------------------------------------------------------------- saving files

/// Saves into the phone's Download folder (falls back to the app folder) and shows a toast with Open / Share.
Future<void> saveAndOffer(BuildContext context, String fileName, List<int> bytes, String mime) async {
  File? f;
  try {
    final dl = Directory('/storage/emulated/0/Download');
    if (Platform.isAndroid && await dl.exists()) {
      f = File('${dl.path}/$fileName');
      await f.writeAsBytes(bytes, flush: true);
    }
  } catch (_) {
    f = null;
  }
  if (f == null) {
    final dir = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
    f = File('${dir.path}/$fileName');
    await f.writeAsBytes(bytes, flush: true);
  }
  if (!context.mounted) return;
  final path = f.path;
  toast(
    context,
    context.t('Report downloaded'),
    kind: DripKind.ok,
    detail: path.contains('/Download/') ? '${context.t('Saved in Downloads')} · $fileName' : fileName,
    action: context.t('Open'),
    onAction: () async {
      final r = await OpenFilex.open(path, type: mime);
      if (r.type != ResultType.done) await Share.shareXFiles([XFile(path, mimeType: mime)]);
    },
  );
}

/// Simple one-table PDF report.
Future<List<int>> simplePdf(String title, List<List<String>> rows, {List<String>? head}) async {
  final doc = pw.Document();
  String clean(String s) => s.replaceAll('₹', 'Rs. ').replaceAll('–', '-').replaceAll('·', '-');
  doc.addPage(
    pw.MultiPage(
      pageFormat: pw.PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (_) => [
        pw.Text('GymMantra', style: pw.TextStyle(color: pw.PdfColor.fromInt(0xFFFF5A1F), fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(clean(title), style: const pw.TextStyle(fontSize: 12)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: head?.map(clean).toList(),
          data: [for (final r in rows) r.map(clean).toList()],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: pw.PdfColors.white, fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: pw.PdfColor.fromInt(0xFF15171C)),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerLeft,
          oddRowDecoration: const pw.BoxDecoration(color: pw.PdfColor.fromInt(0xFFF4F5F7)),
        ),
        pw.SizedBox(height: 10),
        pw.Text('Made in the GymMantra app', style: const pw.TextStyle(fontSize: 8, color: pw.PdfColors.grey600)),
      ],
    ),
  );
  return doc.save();
}

/// "Download PDF" and "Excel (CSV)" buttons.
class DownloadButtons extends StatelessWidget {
  const DownloadButtons({super.key, required this.fileBase, required this.csv, required this.pdfTitle, required this.pdfRows, this.pdfHead, this.accent});
  final String fileBase;
  final String Function() csv;
  final String pdfTitle;
  final List<List<String>> Function() pdfRows;
  final List<String>? pdfHead;
  final Color? accent;
  @override
  Widget build(BuildContext context) {
    final a = accent ?? context.c.primary;
    final safe = fileBase.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: a, minimumSize: const Size.fromHeight(48)),
            onPressed: () async {
              try {
                final bytes = await simplePdf(pdfTitle, pdfRows(), head: pdfHead);
                if (context.mounted) await saveAndOffer(context, '$safe.pdf', bytes, 'application/pdf');
              } catch (e) {
                if (context.mounted) toastError(context, e);
              }
            },
            icon: const Icon(Icons.download_rounded),
            label: Text(context.t('Download PDF')),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () async {
              try {
                await saveAndOffer(context, '$safe.csv', utf8.encode('\uFEFF${csv()}'), 'text/csv');
              } catch (e) {
                if (context.mounted) toastError(context, e);
              }
            },
            child: Text(context.t('Excel (CSV)')),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Muted(context.t('The file is saved in the phone\'s Downloads folder. Tap "Open" in the message to see it.'), size: 11.5),
    ]);
  }
}

