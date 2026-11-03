import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/common.dart';

class EquipmentItem {
  EquipmentItem(Map<String, dynamic> r)
      : id = r['id'] as String,
        number = r['machine_number'] as int,
        name = r['name'] as String,
        description = r['description'] as String?,
        videoUrl = r['video_url'] as String?,
        thumbnailUrl = r['thumbnail_url'] as String?,
        notes = r['notes'] as String?,
        isActive = r['is_active'] as bool;

  final String id;
  final int number;
  final String name;
  final String? description;
  final String? videoUrl;
  final String? thumbnailUrl;
  final String? notes;
  final bool isActive;
}

class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({super.key});

  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  List<EquipmentItem>? _items;
  String? _error;
  String _query = '';
  bool _showInactive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await db.from('equipment').select().order('machine_number');
      if (!mounted) return;
      setState(() {
        _items = [for (final r in rows) EquipmentItem(r)];
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load equipment. Pull down to retry.');
    }
  }

  Future<void> _edit([EquipmentItem? item]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => EquipmentFormScreen(existing: item)));
    if (saved == true) _load();
  }

  Future<void> _toggle(EquipmentItem e) async {
    final ok = await attempt(context, () async {
      await db.from('equipment').update({'is_active': !e.isActive}).eq('id', e.id);
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = _items
        ?.where((e) =>
            (_showInactive || e.isActive) &&
            (e.name.toLowerCase().contains(q) || '${e.number}'.contains(q)))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Equipment')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add equipment'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: 'Search by name or machine number',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Show inactive'),
          value: _showInactive,
          onChanged: (v) => setState(() => _showInactive = v),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: shown == null
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Center(
                        child: _error == null
                            ? const CircularProgressIndicator()
                            : Text(_error!)),
                  ])
                : ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      if (shown.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('No equipment found.'))),
                      for (final e in shown) _tile(e),
                    ],
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _tile(EquipmentItem e) {
    return Opacity(
      opacity: e.isActive ? 1 : 0.55,
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: (e.thumbnailUrl ?? '').isEmpty
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    alignment: Alignment.center,
                    child: Text('#${e.number}'),
                  )
                : Image.network(
                    e.thumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
        ),
        title: Text('#${e.number}  ${e.name}'),
        subtitle: Text([
          if ((e.description ?? '').isNotEmpty) e.description!,
          if ((e.videoUrl ?? '').isNotEmpty) 'Video linked',
          if (!e.isActive) 'Inactive',
        ].join('  ·  ')),
        isThreeLine: false,
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'edit' ? _edit(e) : _toggle(e),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(
                value: 'toggle',
                child: Text(e.isActive ? 'Deactivate' : 'Activate')),
          ],
        ),
        onTap: () => _edit(e),
      ),
    );
  }
}

class EquipmentFormScreen extends StatefulWidget {
  const EquipmentFormScreen({super.key, this.existing});
  final EquipmentItem? existing;

  @override
  State<EquipmentFormScreen> createState() => _EquipmentFormScreenState();
}

class _EquipmentFormScreenState extends State<EquipmentFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _number =
      TextEditingController(text: widget.existing?.number.toString());
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _desc = TextEditingController(text: widget.existing?.description);
  late final _video = TextEditingController(text: widget.existing?.videoUrl);
  late final _thumb = TextEditingController(text: widget.existing?.thumbnailUrl);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late bool _active = widget.existing?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_number, _name, _desc, _video, _thumb, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _n(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  String? _urlCheck(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final u = Uri.tryParse(t);
    return u != null && (u.scheme == 'http' || u.scheme == 'https')
        ? null
        : 'Enter a full link starting with https://';
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final data = {
      'machine_number': int.parse(_number.text.trim()),
      'name': _name.text.trim(),
      'description': _n(_desc),
      'video_url': _n(_video),
      'thumbnail_url': _n(_thumb),
      'notes': _n(_notes),
      'is_active': _active,
    };
    try {
      if (widget.existing == null) {
        await db.from('equipment').insert(data);
      } else {
        await db.from('equipment').update(data).eq('id', widget.existing!.id);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(
          context,
          e.code == '23505'
              ? 'That machine number is already used.'
              : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null ? 'New equipment' : 'Edit equipment')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _number,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Machine number', border: OutlineInputBorder()),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n <= 0 ? 'Enter a whole number above 0' : null;
              },
            ),
            gap,
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            gap,
            TextFormField(
              controller: _desc,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder()),
            ),
            gap,
            TextFormField(
              controller: _video,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Video link (optional)',
                  helperText: 'e.g. a YouTube or Vimeo link',
                  border: OutlineInputBorder()),
              validator: _urlCheck,
            ),
            gap,
            TextFormField(
              controller: _thumb,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Photo link (optional)',
                  helperText: 'A link to an image, shown as the thumbnail',
                  border: OutlineInputBorder()),
              validator: _urlCheck,
            ),
            gap,
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              subtitle: const Text('Inactive equipment is hidden from members'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            gap,
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
