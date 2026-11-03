import 'package:flutter/material.dart';

import '../shared/common.dart';

/// Coach holidays: sessions in the chosen dates are cancelled and not offered to members.
class CoachTimeOffScreen extends StatefulWidget {
  const CoachTimeOffScreen({super.key});

  @override
  State<CoachTimeOffScreen> createState() => _CoachTimeOffScreenState();
}

class _CoachTimeOffScreenState extends State<CoachTimeOffScreen> {
  final _loader = GlobalKey<LoaderState<List<Map<String, dynamic>>>>();

  Future<void> _add() async {
    final today = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(today.year + 2),
      helpText: 'Choose your time off',
    );
    if (range == null || !mounted) return;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Book time off'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(range.start == range.end
                ? showDate(range.start)
                : '${showDate(range.start)} to ${showDate(range.end)}'),
            const SizedBox(height: 8),
            const Text(
                'Your sessions on these days are removed, so members cannot book them.'),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: const InputDecoration(
                  labelText: 'Note (optional)', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue')),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (ok != true || !mounted) return;

    // Tell the coach how many booked sessions would be cancelled before doing it.
    var booked = 0;
    final okPreview = await attempt(context, () async {
      booked = await db.rpc('coach_time_off_preview', params: {
        'p_start': isoDate(range.start),
        'p_end': isoDate(range.end),
      }) as int;
    });
    if (!okPreview || !mounted) return;
    if (booked > 0) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Members are booked'),
          content: Text(
              '$booked booked session${booked == 1 ? '' : 's'} in this period will be '
              'cancelled. No credits are lost, but the members will need to book '
              'another time. Please tell them.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Back')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Cancel them and book time off')),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    final saved = await attempt(context, () async {
      await db.rpc('coach_add_time_off', params: {
        'p_start': isoDate(range.start),
        'p_end': isoDate(range.end),
        'p_note': text.isEmpty ? null : text,
        'p_cancel_bookings': booked > 0,
      });
    });
    if (saved) {
      if (mounted) snack(context, 'Time off booked');
      _loader.currentState?.reload();
    }
  }

  Future<void> _remove(Map<String, dynamic> t) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this time off?'),
        content: const Text(
            'Your sessions in these dates become available again. Members whose '
            'bookings were cancelled are not rebooked automatically.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('coach_remove_time_off', params: {'p_id': t['id']});
    });
    if (ok) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My time off')),
      body: Loader<List<Map<String, dynamic>>>(
        key: _loader,
        load: () async {
          final rows = await db
              .from('coach_time_off')
              .select('id, start_date, end_date, note')
              .eq('coach_id', db.auth.currentUser!.id)
              .gte('end_date', isoDate(DateTime.now()))
              .order('start_date') as List;
          return rows.cast<Map<String, dynamic>>();
        },
        builder: (context, rows, reload) {
          if (rows.isEmpty) {
            return ListView(children: const [
              SizedBox(height: 80),
              Center(child: Text('No time off booked')),
            ]);
          }
          return ListView(
            children: [
              for (final t in rows)
                ListTile(
                  leading: const Icon(Icons.beach_access_outlined),
                  title: Text(t['start_date'] == t['end_date']
                      ? showIso(t['start_date'] as String)
                      : '${showIso(t['start_date'] as String)} to ${showIso(t['end_date'] as String)}'),
                  subtitle: (t['note'] as String?)?.isNotEmpty == true
                      ? Text(t['note'] as String)
                      : null,
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(t),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Book time off'),
      ),
    );
  }
}
