import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

/// Exercise guides: category tiles first; a tap opens that category's exercises. Search covers every exercise.
class WorkoutsScreen extends ConsumerStatefulWidget {
  const WorkoutsScreen({super.key});
  @override
  ConsumerState<WorkoutsScreen> createState() => _WorkoutsState();
}

class _WorkoutsState extends ConsumerState<WorkoutsScreen> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(exercisesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Exercise guides'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(exercisesProvider),
        loading: Padding(
          padding: const EdgeInsets.all(16),
          child: Shimmer(
            child: Column(children: [
              const Bone(height: 50),
              const SizedBox(height: 12),
              for (var i = 0; i < 3; i++) ...[
                const Row(children: [Expanded(child: Bone(height: 150)), SizedBox(width: 10), Expanded(child: Bone(height: 150))]),
                const SizedBox(height: 10),
              ],
            ]),
          ),
        ),
        builder: (d) {
          final all = (d as List).cast<Map>();
          final cats = <String, List<Map>>{};
          for (final e in all) {
            cats.putIfAbsent('${e['category'] ?? e['muscle']}', () => []).add(e);
          }
          final found = all.where((e) => '${e['name']} ${e['category'] ?? e['muscle']}'.toLowerCase().contains(q.toLowerCase())).toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            TextField(decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search exercise or muscle')), onChanged: (t) => setState(() => q = t.trim())),
            const SizedBox(height: 12),
            if (q.isEmpty)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.05),
                itemCount: cats.length,
                itemBuilder: (_, i) {
                  final name = cats.keys.elementAt(i);
                  final list = cats[name]!;
                  return _CategoryTile(name: name, count: list.length, still: list.first['stillUrl'] as String, onTap: () => context.push('/exercises/category', extra: {'name': name, 'items': list}));
                },
              )
            else if (found.isEmpty)
              Padding(padding: const EdgeInsets.all(30), child: Muted(context.t('No exercise found.'), align: TextAlign.center))
            else
              ExerciseGrid(items: found),
          ]);
        },
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.name, required this.count, required this.still, required this.onTap});
  final String name;
  final int count;
  final String still;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.c.surf,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: context.c.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          _Still(still),
          const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xD9000000)], stops: [0.35, 1]))),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t(name), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
              Text(context.t('{n} exercises', {'n': count}), style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Still extends StatelessWidget {
  const _Still(this.url);
  final String url;
  @override
  Widget build(BuildContext context) => Image.network(
        Api.instance.url(url),
        fit: BoxFit.cover,
        width: double.infinity,
        cacheWidth: 400,
        frameBuilder: (_, child, frame, sync) => sync || frame != null ? child : Container(color: context.c.surf2),
        errorBuilder: (_, __, ___) => Center(child: Icon(Icons.fitness_center_rounded, color: context.c.mut)),
      );
}

/// One category's exercises.
class ExerciseCategoryScreen extends StatelessWidget {
  const ExerciseCategoryScreen({super.key, required this.name, required this.items});
  final String name;
  final List<Map> items;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t(name))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Muted(context.t('{n} exercises', {'n': items.length})),
          const SizedBox(height: 12),
          ExerciseGrid(items: items),
        ]),
      );
}

class ExerciseGrid extends StatelessWidget {
  const ExerciseGrid({super.key, required this.items});
  final List<Map> items;
  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.86),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final e = items[i];
        return Material(
          color: context.c.surf,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: context.c.line)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/exercise', extra: e),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Still(e['stillUrl'] as String)),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e['name'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  Text(context.t('${e['category'] ?? e['muscle']}'), style: TextStyle(color: context.c.primary, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class ExerciseScreen extends StatefulWidget {
  const ExerciseScreen({super.key, required this.exercise});
  final Map exercise;
  @override
  State<ExerciseScreen> createState() => _ExerciseState();
}

class _ExerciseState extends State<ExerciseScreen> {
  late final VideoPlayerController c;
  String? error;

  @override
  void initState() {
    super.initState();
    c = VideoPlayerController.networkUrl(Uri.parse(Api.instance.url(widget.exercise['videoUrl'] as String)))
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) setState(() {});
        c.play();
      }).catchError((_) {
        if (mounted) setState(() => error = 'Could not load the video. Check your internet.');
      });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.exercise;
    return Scaffold(
      appBar: AppBar(title: Text(e['name'])),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: c.value.isInitialized ? c.value.aspectRatio : 9 / 16,
            child: c.value.isInitialized
                ? GestureDetector(onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()), child: VideoPlayer(c))
                : Container(color: context.c.surf, child: Center(child: error != null ? Muted(context.t(error!), align: TextAlign.center) : const CircularProgressIndicator(color: C.orange))),
          ),
        ),
        const SizedBox(height: 14),
        Text(e['name'], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Text(context.t('${e['category'] ?? e['muscle']}'), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Muted(context.t('Top: wrong form. Bottom: correct form. Tap the video to pause.')),
      ]),
    );
  }
}
