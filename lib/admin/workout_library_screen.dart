import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/common.dart';
import '../shared/exercise_media.dart';

/// Admin: muscle groups (Shoulders, Chest, Legs, Core...) and their exercises.
class WorkoutLibraryScreen extends StatefulWidget {
  const WorkoutLibraryScreen({super.key});

  @override
  State<WorkoutLibraryScreen> createState() => _WorkoutLibraryScreenState();
}

class _WorkoutLibraryScreenState extends State<WorkoutLibraryScreen> {
  final _loader = GlobalKey<LoaderState<List<Map<String, dynamic>>>>();
  bool _showInactive = false;

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await db
        .from('muscle_groups')
        .select('id, name, sort_order, is_active, exercises(id, is_active)')
        .order('sort_order', ascending: true)
        .order('name', ascending: true) as List;
    return rows.cast<Map<String, dynamic>>();
  }

  Future<void> _edit([Map<String, dynamic>? g, int nextOrder = 0]) async {
    final result = await showDialog<({String name, String? notes})>(
      context: context,
      builder: (_) => _NameDialog(
          title: g == null ? 'New muscle group' : 'Rename muscle group',
          label: 'Name, e.g. Back',
          name: g?['name'] as String?),
    );
    if (result == null || !mounted) return;
    final ok = await _save(() async {
      if (g == null) {
        await db
            .from('muscle_groups')
            .insert({'name': result.name, 'sort_order': nextOrder});
      } else {
        await db.from('muscle_groups').update({'name': result.name}).eq('id', g['id']);
      }
    });
    if (ok) _loader.currentState?.reload();
  }

  Future<void> _toggle(Map<String, dynamic> g) async {
    final ok = await attempt(context, () async {
      await db
          .from('muscle_groups')
          .update({'is_active': !(g['is_active'] as bool)}).eq('id', g['id']);
    });
    if (ok) _loader.currentState?.reload();
  }

  Future<bool> _save(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on PostgrestException catch (e) {
      if (mounted) {
        snack(context, e.code == '23505' ? 'That name is already used.' : e.message);
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workouts')),
      body: Loader<List<Map<String, dynamic>>>(
        key: _loader,
        load: _load,
        builder: (context, groups, reload) {
          final shown =
              groups.where((g) => _showInactive || g['is_active'] == true).toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                    'Muscle groups and their exercises. Coaches pick from these '
                    'when they give a member a workout.'),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Show switched off'),
                value: _showInactive,
                onChanged: (v) => setState(() => _showInactive = v),
              ),
              if (shown.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No muscle groups yet.'))),
              for (final g in shown)
                Opacity(
                  opacity: g['is_active'] == true ? 1 : 0.55,
                  child: ListTile(
                    leading: const Icon(Icons.fitness_center),
                    title: Text(g['name'] as String),
                    subtitle: Text([
                      '${(g['exercises'] as List).where((e) => e['is_active'] == true).length} exercises',
                      if (g['is_active'] != true) 'Switched off',
                    ].join('  ·  ')),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => v == 'rename' ? _edit(g) : _toggle(g),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(
                            value: 'toggle',
                            child: Text(
                                g['is_active'] == true ? 'Switch off' : 'Switch on')),
                      ],
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => MuscleGroupScreen(
                              groupId: g['id'] as String,
                              name: g['name'] as String)));
                      _loader.currentState?.reload();
                    },
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final groups = await _load();
          final next = groups.isEmpty
              ? 1
              : groups.map((g) => g['sort_order'] as int).reduce((a, b) => a > b ? a : b) + 1;
          _edit(null, next);
        },
        icon: const Icon(Icons.add),
        label: const Text('Add muscle group'),
      ),
    );
  }
}

/// Admin: the exercises in one muscle group.
class MuscleGroupScreen extends StatefulWidget {
  const MuscleGroupScreen({super.key, required this.groupId, required this.name});
  final String groupId;
  final String name;

  @override
  State<MuscleGroupScreen> createState() => _MuscleGroupScreenState();
}

class _MuscleGroupScreenState extends State<MuscleGroupScreen> {
  final _loader = GlobalKey<LoaderState<List<Map<String, dynamic>>>>();
  bool _showInactive = false;
  List<Map<String, dynamic>> _rows = [];

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await db
        .from('exercises')
        .select('id, name, notes, video_url, image_urls, sort_order, is_active')
        .eq('muscle_group_id', widget.groupId)
        .order('sort_order', ascending: true)
        .order('name', ascending: true) as List;
    _rows = rows.cast<Map<String, dynamic>>();
    return _rows;
  }

  Future<void> _edit([Map<String, dynamic>? e]) async {
    final next = _rows.isEmpty
        ? 1
        : _rows.map((r) => r['sort_order'] as int).reduce((a, b) => a > b ? a : b) + 1;
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ExerciseFormScreen(
            groupId: widget.groupId, existing: e, nextOrder: next)));
    if (saved == true) _loader.currentState?.reload();
  }

  Future<void> _toggle(Map<String, dynamic> e) async {
    final ok = await attempt(context, () async {
      await db
          .from('exercises')
          .update({'is_active': !(e['is_active'] as bool)}).eq('id', e['id']);
    });
    if (ok) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: Loader<List<Map<String, dynamic>>>(
        key: _loader,
        load: _load,
        builder: (context, rows, reload) {
          final shown =
              rows.where((r) => _showInactive || r['is_active'] == true).toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              SwitchListTile(
                dense: true,
                title: const Text('Show switched off'),
                subtitle: const Text(
                    'Switched-off exercises cannot be picked for new workouts'),
                value: _showInactive,
                onChanged: (v) => setState(() => _showInactive = v),
              ),
              if (shown.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No exercises yet.'))),
              for (final e in shown)
                Opacity(
                  opacity: e['is_active'] == true ? 1 : 0.55,
                  child: ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: imageList(e['image_urls']).isEmpty
                            ? Container(
                                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                                child: const Icon(Icons.fitness_center, size: 20))
                            : ExerciseImage(url: imageList(e['image_urls']).first),
                      ),
                    ),
                    title: Text(e['name'] as String),
                    subtitle: Text(_summary(e)),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => v == 'edit' ? _edit(e) : _toggle(e),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(
                            value: 'toggle',
                            child: Text(
                                e['is_active'] == true ? 'Switch off' : 'Switch on')),
                      ],
                    ),
                    onTap: () => _edit(e),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add exercise'),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.label,
    this.name,
  });
  final String title;
  final String label;
  final String? name;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.name);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: widget.label,
                errorText: _error,
                border: const OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final n = _name.text.trim();
            if (n.isEmpty) {
              setState(() => _error = 'Enter a name');
              return;
            }
            Navigator.pop(context, (name: n, notes: null));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _summary(Map<String, dynamic> e) {
  final n = imageList(e['image_urls']).length;
  final parts = [
    if ((e['notes'] as String?)?.isNotEmpty ?? false) 'Steps',
    if (n > 0) '$n ${n == 1 ? 'photo' : 'photos'}',
    if (hasVideo(e)) 'Video',
    if (e['is_active'] != true) 'Switched off',
  ];
  return parts.isEmpty ? 'No how-to yet' : parts.join('  ·  ');
}

/// A photo in the form: already saved ([url]) or just picked ([bytes]).
class _Photo {
  _Photo.saved(this.url) : bytes = null;
  _Photo.picked(this.bytes) : url = null;
  final String? url;
  final Uint8List? bytes;
}

/// Admin: add or change an exercise, with its "how to" steps, photos and video.
class ExerciseFormScreen extends StatefulWidget {
  const ExerciseFormScreen(
      {super.key, required this.groupId, this.existing, this.nextOrder = 0});
  final String groupId;
  final Map<String, dynamic>? existing;
  final int nextOrder;

  @override
  State<ExerciseFormScreen> createState() => _ExerciseFormScreenState();
}

class _ExerciseFormScreenState extends State<ExerciseFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?['name'] as String?);
  late final _notes = TextEditingController(text: widget.existing?['notes'] as String?);
  late final _video =
      TextEditingController(text: widget.existing?['video_url'] as String?);
  late final List<_Photo> _photos = [
    for (final u in imageList(widget.existing?['image_urls'])) _Photo.saved(u)
  ];
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _video.dispose();
    super.dispose();
  }

  Future<void> _addPhotos() async {
    final left = maxExerciseImages - _photos.length;
    if (left <= 0) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(left == 1 ? 'Choose from gallery' : 'Choose from gallery (up to $left)'),
            onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      // Shrunk on the phone so uploads stay small.
      final picker = ImagePicker();
      final List<XFile> files;
      if (source == ImageSource.gallery && left > 1) {
        files = await picker.pickMultiImage(
            maxWidth: 1280, maxHeight: 1280, imageQuality: 80, limit: left);
      } else {
        final one = await picker.pickImage(
            source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
        files = one == null ? [] : [one];
      }
      final added = <_Photo>[];
      for (final f in files.take(left)) {
        added.add(_Photo.picked(await f.readAsBytes()));
      }
      if (!mounted) return;
      if (files.length > left) {
        snack(context, 'Only $maxExerciseImages photos per exercise; extra ones were skipped.');
      }
      setState(() => _photos.addAll(added));
    } catch (_) {
      if (mounted) snack(context, 'Could not open the photo picker.');
    }
  }

  String? _urlCheck(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final u = Uri.tryParse(t);
    return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty
        ? null
        : 'Enter a full link starting with https://';
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final uploaded = <String>[];
    try {
      final urls = <String>[];
      for (final p in _photos) {
        if (p.url != null) {
          urls.add(p.url!);
        } else {
          final u = await uploadExerciseImage(p.bytes!);
          uploaded.add(u);
          urls.add(u);
        }
      }
      final notes = _notes.text.trim();
      final video = _video.text.trim();
      final data = {
        'name': _name.text.trim(),
        'notes': notes.isEmpty ? null : notes,
        'video_url': video.isEmpty ? null : video,
        'image_urls': urls,
      };
      if (widget.existing == null) {
        await db.from('exercises').insert({
          ...data,
          'muscle_group_id': widget.groupId,
          'sort_order': widget.nextOrder,
        });
      } else {
        await db.from('exercises').update(data).eq('id', widget.existing!['id']);
        // Photos the admin removed are deleted from storage.
        final before = imageList(widget.existing!['image_urls']);
        await deleteExerciseImages(before.where((u) => !urls.contains(u)));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      await deleteExerciseImages(uploaded); // nothing was saved, tidy up
      if (!mounted) return;
      setState(() => _saving = false);
      snack(
          context,
          e is PostgrestException
              ? (e.code == '23505' ? 'That exercise is already in this group.' : e.message)
              : e is StorageException
                  ? 'Could not upload a photo: ${e.message}'
                  : 'Something went wrong. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New exercise' : 'Edit exercise'),
        actions: [
          IconButton(
            tooltip: 'Preview what members see',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () {
              final saved = [for (final p in _photos) if (p.url != null) p.url!];
              if (_photos.length > saved.length) {
                snack(context, 'New photos show in the preview after you save.');
              }
              showExerciseHowTo(context, {
                'name': _name.text.trim(),
                'notes': _notes.text.trim(),
                'video_url': _video.text.trim(),
                'image_urls': saved,
              });
            },
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Exercise name, e.g. Squat', border: OutlineInputBorder()),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            gap,
            TextFormField(
              controller: _notes,
              minLines: 4,
              maxLines: 12,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'How to do it (optional)',
                  hintText: '1. Stand with feet shoulder-width apart\n2. ...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder()),
            ),
            gap,
            TextFormField(
              controller: _video,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Video link (optional)',
                  helperText: 'e.g. a YouTube or Vimeo link. Members see "View video".',
                  border: OutlineInputBorder()),
              validator: _urlCheck,
            ),
            gap,
            Text('Photos (${_photos.length} of $maxExerciseImages)',
                style: theme.textTheme.titleMedium),
            Text('The first photo is shown as the thumbnail.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var i = 0; i < _photos.length; i++) _photoTile(i),
                if (_photos.length < maxExerciseImages)
                  InkWell(
                    onTap: _saving ? null : _addPhotos,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.colorScheme.outline),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [Icon(Icons.add_a_photo_outlined), Text('Add photo')],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoTile(int i) {
    final p = _photos[i];
    return Stack(fit: StackFit.expand, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: p.bytes != null
            ? Image.memory(p.bytes!, fit: BoxFit.cover)
            : ExerciseImage(url: p.url!),
      ),
      Positioned(
        top: 2,
        right: 2,
        child: IconButton.filledTonal(
          visualDensity: VisualDensity.compact,
          tooltip: 'Remove photo',
          onPressed: _saving ? null : () => setState(() => _photos.removeAt(i)),
          icon: const Icon(Icons.close, size: 18),
        ),
      ),
      if (i > 0)
        Positioned(
          bottom: 2,
          left: 2,
          child: IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            tooltip: 'Move left',
            onPressed: _saving
                ? null
                : () => setState(() => _photos.insert(i - 1, _photos.removeAt(i))),
            icon: const Icon(Icons.chevron_left, size: 18),
          ),
        ),
    ]);
  }
}
