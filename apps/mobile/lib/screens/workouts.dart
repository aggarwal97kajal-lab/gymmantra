import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

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
      appBar: AppBar(title: const Text('3D exercise guides')),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(exercisesProvider),
        builder: (d) {
          final all = (d as List).cast<Map>();
          final list = all.where((e) => q.isEmpty || '${e['name']} ${e['muscle']}'.toLowerCase().contains(q.toLowerCase())).toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search exercise or muscle'), onChanged: (t) => setState(() => q = t)),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.62),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final e = list[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => context.push('/exercise', extra: e),
                  child: Container(
                    decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.line)),
                    clipBehavior: Clip.antiAlias,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Image.network(Api.instance.url(e['stillUrl'] as String), fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.fitness_center, color: C.mut)))),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e['name'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                          Text(e['muscle'], style: const TextStyle(color: C.lime, fontSize: 12)),
                        ]),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ]);
        },
      ),
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
                : Container(color: C.card, child: Center(child: error != null ? Muted(error!) : const CircularProgressIndicator(color: C.lime))),
          ),
        ),
        const SizedBox(height: 14),
        Text(e['name'], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Text('Target: ${e['muscle']}', style: const TextStyle(color: C.lime, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Muted('The highlighted muscle is the one this exercise works. Tap the video to pause.'),
      ]),
    );
  }
}
