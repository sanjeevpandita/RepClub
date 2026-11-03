import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/common.dart';

/// Read-only machine library for members.
class MemberEquipmentScreen extends StatefulWidget {
  const MemberEquipmentScreen({super.key});

  @override
  State<MemberEquipmentScreen> createState() => _MemberEquipmentScreenState();
}

class _MemberEquipmentScreenState extends State<MemberEquipmentScreen> {
  String _q = '';
  bool _showAll = false;

  Widget _thumb(String? url, {double size = 56}) {
    final box = SizedBox(
      width: size,
      height: size,
      child: const Icon(Icons.fitness_center),
    );
    if (url == null || url.isEmpty) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => box),
    );
  }

  void _open(Map<String, dynamic> e) {
    final video = e['video_url'] as String?;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((e['thumbnail_url'] as String?)?.isNotEmpty == true)
                Center(child: _thumb(e['thumbnail_url'], size: 200)),
              const SizedBox(height: 12),
              Text('Machine ${e['machine_number']}',
                  style: Theme.of(ctx).textTheme.labelLarge),
              Text(e['name'] as String,
                  style: Theme.of(ctx).textTheme.headlineSmall),
              if ((e['description'] as String?)?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text(e['description'] as String),
              ],
              if ((e['notes'] as String?)?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text('Notes', style: Theme.of(ctx).textTheme.titleSmall),
                Text(e['notes'] as String),
              ],
              if (video != null && video.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Video', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                FilledButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(video);
                    final ok = uri != null &&
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                    if (!ok && ctx.mounted) {
                      snack(ctx, 'Could not open the video link');
                    }
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Watch video'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: video));
                    if (ctx.mounted) snack(ctx, 'Video link copied');
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy video link'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equipment')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search by name or number',
                  border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Assigned to me')),
                  ButtonSegment(value: true, label: Text('All equipment')),
                ],
                selected: {_showAll},
                onSelectionChanged: (s) => setState(() => _showAll = s.first),
              ),
            ),
          ),
          Expanded(
            child: Loader<({List<Map<String, dynamic>> all, Set<String> mine})>(
              load: () async {
                final all = (await db
                        .from('equipment')
                        .select()
                        .eq('is_active', true)
                        .order('machine_number') as List)
                    .cast<Map<String, dynamic>>();
                final mine = await db
                    .from('equipment_assignments')
                    .select('equipment_id')
                    .eq('member_id', db.auth.currentUser!.id) as List;
                return (
                  all: all,
                  mine: {for (final r in mine) r['equipment_id'] as String},
                );
              },
              builder: (context, data, reload) {
                final list = data.all
                    .where((e) => _showAll || data.mine.contains(e['id']))
                    .where((e) =>
                        _q.isEmpty ||
                        (e['name'] as String).toLowerCase().contains(_q) ||
                        '${e['machine_number']}'.contains(_q))
                    .toList();
                if (list.isEmpty) {
                  return ListView(children: [
                    const SizedBox(height: 80),
                    Center(
                        child: Text(!_showAll && data.mine.isEmpty
                            ? 'No equipment assigned to you yet.\nTap "All equipment" to browse the full list.'
                            : 'No equipment found',
                            textAlign: TextAlign.center)),
                  ]);
                }
                return ListView(
                  children: [
                    for (final e in list)
                      ListTile(
                        leading: _thumb(e['thumbnail_url'] as String?),
                        title: Text(e['name'] as String),
                        subtitle: Text('Machine ${e['machine_number']}'),
                        trailing: (e['video_url'] as String?)?.isNotEmpty == true
                            ? const Icon(Icons.play_circle_outline)
                            : null,
                        onTap: () => _open(e),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
