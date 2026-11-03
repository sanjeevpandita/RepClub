import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common.dart';

/// Most photos an exercise can have.
const maxExerciseImages = 5;

const _bucket = 'exercise-media';

/// Uploads one exercise photo and returns its public link. Throws on failure.
Future<String> uploadExerciseImage(Uint8List bytes) async {
  final name =
      'exercises/${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 32)}.jpg';
  final store = db.storage.from(_bucket);
  await store.uploadBinary(
    name,
    bytes,
    fileOptions: const FileOptions(contentType: 'image/jpeg'),
  );
  return store.getPublicUrl(name);
}

/// Deletes photos that are no longer used. Failures are ignored (the photo
/// simply stays in storage).
Future<void> deleteExerciseImages(Iterable<String> urls) async {
  final paths = [
    for (final u in urls)
      if (u.contains('/$_bucket/'))
        Uri.decodeFull(u.split('/$_bucket/').last.split('?').first),
  ];
  if (paths.isEmpty) return;
  try {
    await db.storage.from(_bucket).remove(paths);
  } catch (_) {}
}

List<String> imageList(dynamic v) =>
    v is List ? [for (final x in v) x as String] : const [];

bool hasHowTo(Map ex) =>
    ((ex['notes'] as String?)?.isNotEmpty ?? false) ||
    imageList(ex['image_urls']).isNotEmpty;

bool hasVideo(Map ex) => (ex['video_url'] as String?)?.isNotEmpty ?? false;

Future<void> openVideo(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final ok =
      uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) snack(context, 'Could not open the video link');
}

/// "How to" (always) and "View video" (when there is a link) for an exercise.
class ExerciseHelpButtons extends StatelessWidget {
  const ExerciseHelpButtons({super.key, required this.exercise});
  final Map exercise;

  @override
  Widget build(BuildContext context) {
    final video = hasVideo(exercise);
    return Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => showExerciseHowTo(context, exercise),
          icon: const Icon(Icons.menu_book_outlined, size: 18),
          label: const Text('How to'),
        ),
        if (video)
          OutlinedButton.icon(
            onPressed: () =>
                openVideo(context, exercise['video_url'] as String),
            icon: const Icon(Icons.play_circle_outline, size: 18),
            label: const Text('View video'),
          ),
      ],
    );
  }
}

/// Sheet with the exercise's photos, written steps and video button.
Future<void> showExerciseHowTo(BuildContext context, Map ex) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, scroll) {
        final theme = Theme.of(ctx);
        final images = imageList(ex['image_urls']);
        final notes = ex['notes'] as String?;
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            Text(
              ex['name'] as String? ?? 'Exercise',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (images.isEmpty &&
                !(notes?.isNotEmpty ?? false) &&
                !hasVideo(ex))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: theme.colorScheme.outline),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'No instructions for this exercise yet. '
                        'Ask your coach to show you.',
                      ),
                    ),
                  ],
                ),
              ),
            if (images.isNotEmpty) _Gallery(urls: images),
            if (notes?.isNotEmpty ?? false) ...[
              const SizedBox(height: 16),
              Text('How to do it', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(notes!, style: theme.textTheme.bodyLarge),
            ],
            if (hasVideo(ex)) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => openVideo(ctx, ex['video_url'] as String),
                icon: const Icon(Icons.play_arrow),
                label: const Text('View video'),
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Swipeable photos with dots; tap a photo to see it full screen and zoom.
class _Gallery extends StatefulWidget {
  const _Gallery({required this.urls});
  final List<String> urls;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 280,
          child: PageView.builder(
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _FullImage(urls: widget.urls, start: i),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ExerciseImage(url: widget.urls[i], fit: BoxFit.cover),
                ),
              ),
            ),
          ),
        ),
        if (widget.urls.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.urls.length; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.urls, required this.start});
  final List<String> urls;
  final int start;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: PageView.builder(
        controller: PageController(initialPage: start),
        itemCount: urls.length,
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: ExerciseImage(url: urls[i], fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// A network photo with a spinner while loading and an icon if it fails.
class ExerciseImage extends StatelessWidget {
  const ExerciseImage({super.key, required this.url, this.fit = BoxFit.cover});
  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerHigh;
    return Image.network(
      url,
      fit: fit,
      width: double.infinity,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : Container(
              color: bg,
              alignment: Alignment.center,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
      errorBuilder: (_, _, _) => Container(
        color: bg,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}
