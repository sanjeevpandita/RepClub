import 'package:flutter/material.dart';

import '../shared/common.dart';

/// More > Missed sessions: finished sessions nobody checked in to (still
/// "Booked"). Nothing is marked automatically any more (db/29): the admin
/// looks at the list and marks them all as no-shows by hand.
class MissedSessionsScreen extends StatefulWidget {
  const MissedSessionsScreen({super.key});

  @override
  State<MissedSessionsScreen> createState() => _MissedSessionsScreenState();
}

class _MissedSessionsScreenState extends State<MissedSessionsScreen> {
  final _loader = GlobalKey<LoaderState<Map<String, dynamic>>>();

  Future<Map<String, dynamic>> _load() async {
    final res = await db.rpc(
      'admin_mark_past_no_shows',
      params: {'p_apply': false},
    );
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _apply(int coach, int gym) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark all as no-show?'),
        content: Text(
          [
            if (coach > 0)
              '$coach coach ${coach == 1 ? 'session' : 'sessions'}: '
                  'each member loses 1 credit.',
            if (gym > 0)
              '$gym gym ${gym == 1 ? 'hour' : 'hours'}: no credit is taken.',
            'A credit can be given back later with "Waive no-show".',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Mark as no-show'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('admin_mark_past_no_shows', params: {'p_apply': true});
    });
    if (!ok || !mounted) return;
    snack(context, 'Marked ${coach + gym} as no-show');
    await _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Missed sessions')),
      body: Loader<Map<String, dynamic>>(
        key: _loader,
        load: _load,
        builder: (context, data, reload) {
          final items = (data['items'] as List).cast<Map>();
          final coach = data['no_shows'] as int;
          final gym = data['gym_no_shows'] as int;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                'Finished sessions where nobody checked in. They are no longer '
                'marked as no-shows automatically at night.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('No missed sessions.')),
                ),
              if (items.isNotEmpty) ...[
                FilledButton.icon(
                  onPressed: () => _apply(coach, gym),
                  icon: const Icon(Icons.person_off_outlined),
                  label: Text('Mark all ${items.length} as no-show'),
                ),
                const SizedBox(height: 8),
              ],
              for (final i in items)
                () {
                  final start = DateTime.parse(i['starts_at'] as String)
                      .toLocal();
                  final end = DateTime.parse(i['ends_at'] as String).toLocal();
                  final isGym = i['kind'] == 'GYM';
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        isGym ? Icons.fitness_center : Icons.person_outline,
                      ),
                      title: Text((i['member'] as String?) ?? 'Member'),
                      subtitle: Text(
                        '${showDate(start)}  ${showTime(start)}-${showTime(end)}'
                        '  ·  ${isGym ? 'Gym time' : 'Coach ${i['coach'] ?? ''}'}',
                      ),
                    ),
                  );
                }(),
            ],
          );
        },
      ),
    );
  }
}
