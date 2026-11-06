import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'festival.dart';
import 'i18n.dart';
import 'screens/billing.dart' show loadIndia;
import 'theme.dart';
import 'ui.dart';

/// GM Admin → Festivals: which festival look the apps show, when, to whom, with or without sound.
class AdminFestivals extends StatefulWidget {
  const AdminFestivals({super.key});
  @override
  State<AdminFestivals> createState() => _AdminFestivalsState();
}

class _AdminFestivalsState extends State<AdminFestivals> {
  List<Map>? items;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await Api.instance.get('/super/festivals');
      if (mounted) setState(() => items = (r as List).cast<Map>());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> open([Map? f]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => FestivalEditScreen(fest: f)));
    if (changed == true) load();
  }

  String _when(Map f) {
    final a = DateTime.tryParse('${f['from']}')?.toLocal();
    final b = DateTime.tryParse('${f['to']}')?.toLocal();
    if (a == null || b == null) return '';
    String d(DateTime x) => '${x.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][x.month - 1]} ${x.year}';
    return '${d(a)} → ${d(b)}';
  }

  String _status(Map f) {
    final now = DateTime.now();
    final a = DateTime.tryParse('${f['from']}')?.toLocal();
    final b = DateTime.tryParse('${f['to']}')?.toLocal();
    if (f['active'] != true) return 'Off';
    if (a != null && now.isBefore(a)) return 'Scheduled';
    if (b != null && now.isAfter(b)) return 'Ended';
    return 'Live';
  }

  @override
  Widget build(BuildContext context) {
    final list = items ?? const <Map>[];
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Festivals'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => open(), icon: const Icon(Icons.add_rounded), label: Text(context.t('New festival look'))),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
          Muted(context.t('On these days the apps open with the festival animation and sound, and show a festival banner, tab icons and tap sparkles. No app update needed.'), size: 12.5),
          const SizedBox(height: 12),
          if (items == null && error == null) const ListSkeleton(first: 70, rows: 4),
          if (error != null) ErrorText(error),
          if (items != null && list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('No festival yet. Tap "New festival look".'), align: TextAlign.center)),
          for (final f in list) ...[
            Panel(
              onTap: () => open(f),
              child: Row(children: [
                Text(festSpecs[f['kind']]?.hero ?? '🎉', style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${f['title']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Muted(_when(f), size: 12),
                    Muted([
                      (f['roles'] as List?)?.isNotEmpty == true ? (f['roles'] as List).join(', ') : context.t('Everyone'),
                      (f['states'] as List?)?.isNotEmpty == true ? (f['states'] as List).join(', ') : context.t('All states'),
                      f['sound'] == true ? '🔊' : '🔇',
                    ].join(' · '), size: 11.5),
                  ]),
                ),
                _pill(context, _status(f)),
              ]),
            ),
            const SizedBox(height: 10),
          ],
        ]),
      ),
    );
  }

  Widget _pill(BuildContext context, String s) {
    final c = switch (s) { 'Live' => C.ok, 'Scheduled' => C.indigo, _ => context.c.mut };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withAlpha(30), borderRadius: BorderRadius.circular(99)),
      child: Text(context.t(s), style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 11.5)),
    );
  }
}

class FestivalEditScreen extends StatefulWidget {
  const FestivalEditScreen({super.key, this.fest});
  final Map? fest;
  @override
  State<FestivalEditScreen> createState() => _FestivalEditState();
}

class _FestivalEditState extends State<FestivalEditScreen> {
  late String kind = (widget.fest?['kind'] as String?) ?? 'diwali';
  late final title = TextEditingController(text: (widget.fest?['title'] as String?) ?? festSpecs[kind]!.greet);
  late final sub = TextEditingController(text: (widget.fest?['sub'] as String?) ?? '');
  late DateTime from = DateTime.tryParse('${widget.fest?['from']}')?.toLocal() ?? DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, 6);
  late DateTime to = DateTime.tryParse('${widget.fest?['to']}')?.toLocal() ?? from.add(const Duration(days: 2, hours: 17));
  late Set<String> roles = {...((widget.fest?['roles'] as List?) ?? const []).map((e) => '$e')};
  late Set<String> states = {...((widget.fest?['states'] as List?) ?? const []).map((e) => '$e')};
  late bool sound = widget.fest?['sound'] != false;
  late bool every = widget.fest?['every'] == true;
  late bool active = widget.fest?['active'] != false;
  bool busy = false;
  Uint8List? newPic; // picked now, sent on Save
  late bool hasPic = widget.fest?['imageV'] != null;
  bool dropPic = false;

  String? get _picUrl => hasPic && !dropPic ? Api.instance.url('/api/v1/festivals/${widget.fest!['id']}/image?v=${widget.fest!['imageV']}') : null;

  Future<void> pickPic() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1000);
    if (f == null) return;
    final b = await f.readAsBytes();
    if (b.length > 500 * 1024) {
      if (mounted) toast(context, context.t('Picture is too big (max 500 KB). Use a smaller PNG or JPEG.'));
      return;
    }
    setState(() {
      newPic = b;
      dropPic = false;
    });
  }

  Future<void> pick(bool start) async {
    final cur = start ? from : to;
    final d = await showDatePicker(context: context, initialDate: cur, firstDate: DateTime(2025), lastDate: DateTime(2035));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(cur));
    if (!mounted) return;
    final v = DateTime(d.year, d.month, d.day, t?.hour ?? cur.hour, t?.minute ?? cur.minute);
    setState(() => start ? from = v : to = v);
  }

  Future<void> chooseStates() async {
    final all = await loadIndia();
    if (!mounted) return;
    final picked = {...states};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: ListView(children: [
            CheckboxListTile(value: picked.isEmpty, title: Text(ctx.t('All states')), onChanged: (_) => set(() => picked.clear())),
            for (final s in all)
              CheckboxListTile(
                value: picked.contains(s.name),
                title: Text(s.name),
                onChanged: (v) => set(() => v == true ? picked.add(s.name) : picked.remove(s.name)),
              ),
          ]),
        ),
      ),
    );
    setState(() => states = picked);
  }

  void preview() {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (ctx, __, ___) => FestivalSplash(
        fest: null,
        preview: true,
        kind: kind,
        title: title.text.trim().isEmpty ? festSpecs[kind]!.greet : title.text.trim(),
        sound: sound,
        picture: newPic != null ? MemoryImage(newPic!) : (_picUrl != null ? NetworkImage(_picUrl!) as ImageProvider : null),
        onDone: () => Navigator.of(ctx).maybePop(),
      ),
    ));
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      final saved = await Api.instance.put('/super/festivals/${widget.fest?['id'] ?? 'new'}', {
        'kind': kind,
        'title': title.text.trim(),
        'sub': sub.text.trim(),
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'roles': roles.toList(),
        'states': states.toList(),
        'sound': sound,
        'every': every,
        'active': active,
      });
      final id = (saved as Map)['id'];
      if (newPic != null) {
        final png = newPic!.length > 3 && newPic![0] == 0x89 && newPic![1] == 0x50;
        await Api.instance.put('/super/festivals/$id/image', {'mime': png ? 'image/png' : 'image/jpeg', 'base64': base64Encode(newPic!)});
      } else if (dropPic && hasPic) {
        await Api.instance.delete('/super/festivals/$id/image');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Delete this festival look?')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))), FilledButton(style: FilledButton.styleFrom(backgroundColor: C.red), onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Delete')))],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.delete('/super/festivals/${widget.fest!['id']}');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  String _fmt(DateTime x) => '${x.day}/${x.month}/${x.year}  ${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(context.t(t), style: TextStyle(color: context.c.mut, fontWeight: FontWeight.w700, fontSize: 13)));
    Widget role(String k, String l) => FilterChip(
          label: Text(context.t(l)),
          selected: k == 'ALL' ? roles.isEmpty : roles.contains(k),
          onSelected: (_) => setState(() {
            if (k == 'ALL') {
              roles.clear();
            } else {
              roles.contains(k) ? roles.remove(k) : roles.add(k);
            }
          }),
        );
    return Scaffold(
      appBar: AppBar(title: Text(context.t(widget.fest == null ? 'New festival look' : 'Festival look'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        label('Festival'),
        SizedBox(
          height: 92,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final e in festSpecs.entries)
              GestureDetector(
                onTap: () => setState(() {
                  final wasDefault = title.text.trim().isEmpty || title.text == festSpecs[kind]!.greet;
                  kind = e.key;
                  if (wasDefault) title.text = e.value.greet;
                }),
                child: Container(
                  width: 82,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: e.value.bg, begin: Alignment.topCenter, end: Alignment.bottomCenter),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kind == e.key ? C.indigo : Colors.transparent, width: 3),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(e.value.hero, style: const TextStyle(fontSize: 28)),
                    const SizedBox(height: 4),
                    Text(e.value.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
          ]),
        ),
        label('Picture (optional)'),
        Muted(context.t('Shown in the middle of the opening screen and on the Home banner. No picture = animation only. PNG with a clear background looks best (max 500 KB).'), size: 12),
        const SizedBox(height: 8),
        Row(children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(gradient: LinearGradient(colors: festSpecs[kind]!.bg), borderRadius: BorderRadius.circular(14)),
            child: newPic != null
                ? Image.memory(newPic!, fit: BoxFit.contain)
                : (_picUrl != null ? Image.network(_picUrl!, fit: BoxFit.contain) : Icon(Icons.image_outlined, color: Colors.white.withAlpha(150), size: 36)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OutlinedButton.icon(onPressed: pickPic, icon: const Icon(Icons.upload_rounded), label: Text(context.t(newPic != null || _picUrl != null ? 'Change picture' : 'Upload picture'))),
              if (newPic != null || _picUrl != null)
                TextButton(onPressed: () => setState(() {
                      newPic = null;
                      dropPic = true;
                    }), child: Text(context.t('Remove picture'), style: const TextStyle(color: C.red))),
            ]),
          ),
        ]),
        label('Banner heading'),
        TextField(controller: title, maxLength: 60),
        label('Banner line (optional)'),
        TextField(controller: sub, maxLength: 100, decoration: InputDecoration(hintText: context.t('e.g. Roshni aur fitness — dono roz'))),
        label('When'),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => pick(true), child: Text('${context.t('From')}\n${_fmt(from)}', textAlign: TextAlign.center))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => pick(false), child: Text('${context.t('To')}\n${_fmt(to)}', textAlign: TextAlign.center))),
        ]),
        label('Who sees it'),
        Wrap(spacing: 8, runSpacing: 6, children: [role('ALL', 'Everyone'), role('MEMBER', 'Members'), role('TRAINER', 'Trainers'), role('STAFF', 'Staff'), role('OWNER', 'Owners')]),
        label('Where'),
        OutlinedButton.icon(onPressed: chooseStates, icon: const Icon(Icons.map_rounded), label: Text(states.isEmpty ? context.t('All states') : states.join(', '), maxLines: 2, overflow: TextOverflow.ellipsis)),
        const SizedBox(height: 10),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: sound, onChanged: (v) => setState(() => sound = v), title: Text(context.t('Sound')), subtitle: Text(context.t('Plays once a day with the opening animation (not on phones set to silent)'))),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: every, onChanged: (v) => setState(() => every = v), title: Text(context.t('Opening animation every time the app opens')), subtitle: Text(context.t('Off: once a day'))),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setState(() => active = v), title: Text(context.t('On'))),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: preview, icon: const Icon(Icons.play_circle_rounded), label: Text(context.t('Preview on my phone'))),
        const SizedBox(height: 10),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
        if (widget.fest != null) ...[
          const SizedBox(height: 6),
          TextButton(onPressed: remove, child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
        ],
      ]),
    );
  }
}
