import 'package:flutter/material.dart';

import '../shared/common.dart';
import 'time_off_screen.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _daysAhead = 21;

class _Slot {
  _Slot(this.id, this.start, this.end, this.bookingId, this.memberId);
  final String id;
  final DateTime start;
  final DateTime end;
  final String? bookingId; // active booking (BOOKED) on this slot
  final String? memberId;
}

class _Data {
  _Data(this.slots, this.names);
  final List<_Slot> slots;
  final Map<String, String> names;
}

Future<_Data> _load() async {
  final now = DateTime.now();
  final to = DateTime(now.year, now.month, now.day + _daysAhead);
  final rows = await db
      .from('slots')
      .select('id, starts_at, ends_at, bookings(id, status, member_id)')
      .eq('coach_id', db.auth.currentUser!.id)
      .eq('is_cancelled', false)
      .gte('starts_at', now.toUtc().toIso8601String())
      .lt('starts_at', to.toUtc().toIso8601String())
      .order('starts_at') as List;
  final slots = <_Slot>[];
  for (final r in rows) {
    Map? active;
    for (final b in (r['bookings'] as List)) {
      if (b['status'] == 'BOOKED') active = b as Map;
    }
    slots.add(_Slot(
      r['id'] as String,
      DateTime.parse(r['starts_at'] as String).toLocal(),
      DateTime.parse(r['ends_at'] as String).toLocal(),
      active?['id'] as String?,
      active?['member_id'] as String?,
    ));
  }
  final ids = {for (final s in slots) if (s.memberId != null) s.memberId!};
  return _Data(slots, ids.isEmpty ? {} : await nameMap(ids));
}

/// Coach's upcoming sessions: book a member into a free slot, move or cancel.
class CoachScheduleScreen extends StatefulWidget {
  const CoachScheduleScreen({super.key});

  @override
  State<CoachScheduleScreen> createState() => _CoachScheduleScreenState();
}

class _CoachScheduleScreenState extends State<CoachScheduleScreen> {
  final _loader = GlobalKey<LoaderState<_Data>>();
  late DateTime _day = _today();
  String? _moving; // booking id being moved

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _reload() async => _loader.currentState?.reload();

  String _label(_Slot s) =>
      '${_weekdays[s.start.weekday - 1]} ${showDate(s.start)}, ${showTime(s.start)}-${showTime(s.end)}';

  Future<bool> _confirm(String title, String text, String yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<({String id, String name})?> _pickMember() async {
    final mp = await db
        .from('member_profiles')
        .select('id')
        .eq('primary_coach_id', db.auth.currentUser!.id) as List;
    final names = await nameMap([for (final m in mp) m['id'] as String]);
    final list = names.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    if (!mounted) return null;
    return showModalBottomSheet<({String id, String name})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Book which member?')),
            if (list.isEmpty)
              const ListTile(title: Text('You have no members yet.')),
            for (final e in list)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(e.value),
                onTap: () => Navigator.pop(ctx, (id: e.key, name: e.value)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _freeSlotTap(_Slot s) async {
    if (_moving != null) {
      if (!await _confirm('Move session', 'Move the booking to ${_label(s)}?',
          'Move')) {
        return;
      }
      if (!mounted) return;
      final id = _moving!;
      final ok = await attempt(context, () async {
        await db.rpc('reschedule_booking',
            params: {'p_booking': id, 'p_new_slot': s.id});
      });
      if (ok) {
        setState(() => _moving = null);
        if (mounted) snack(context, 'Session moved');
        await _reload();
      }
      return;
    }
    final m = await _pickMember();
    if (m == null || !mounted) return;
    if (!await _confirm('Book session', 'Book ${m.name} on ${_label(s)}?',
        'Book')) {
      return;
    }
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('create_booking', params: {'p_slot': s.id, 'p_member': m.id});
    });
    if (ok) {
      if (mounted) snack(context, 'Session booked');
      await _reload();
    }
  }

  Future<void> _cancel(_Slot s, String name) async {
    if (!await _confirm('Cancel booking',
        'Cancel ${_label(s)} for $name? Sessions within 12 hours cannot be cancelled here.',
        'Cancel booking')) {
      return;
    }
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('cancel_booking', params: {'p_booking': s.bookingId});
    });
    if (ok) {
      if (mounted) snack(context, 'Booking cancelled');
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _today();
    final days = [
      for (var i = 0; i < _daysAhead; i++)
        DateTime(today.year, today.month, today.day + i)
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule'),
        actions: [
          IconButton(
            tooltip: 'My time off',
            icon: const Icon(Icons.beach_access_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const CoachTimeOffScreen()));
              _reload();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 76,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: days.length,
              itemBuilder: (_, i) {
                final d = days[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    selected: _sameDay(d, _day),
                    onSelected: (_) => setState(() => _day = d),
                    label: SizedBox(
                      width: 44,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_weekdays[d.weekday - 1],
                              style: theme.textTheme.labelSmall),
                          Text('${d.day}', style: theme.textTheme.titleMedium),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_moving != null)
            MaterialBanner(
              content: const Text('Choose a free session to move the booking to.'),
              actions: [
                TextButton(
                    onPressed: () => setState(() => _moving = null),
                    child: const Text('Stop moving')),
              ],
            ),
          Expanded(
            child: Loader<_Data>(
              key: _loader,
              load: _load,
              builder: (context, data, reload) {
                final slots =
                    data.slots.where((s) => _sameDay(s.start, _day)).toList();
                if (slots.isEmpty) {
                  return ListView(children: const [
                    SizedBox(height: 80),
                    Center(child: Text('No sessions on this day')),
                  ]);
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [for (final s in slots) _tile(theme, s, data)],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(ThemeData theme, _Slot s, _Data data) {
    final time = '${showTime(s.start)} - ${showTime(s.end)}';
    if (s.bookingId != null) {
      final name = data.names[s.memberId] ?? 'Member';
      return Card(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        child: ListTile(
          leading:
              Icon(Icons.event_available, color: theme.colorScheme.primary),
          title: Text(time),
          subtitle: Text(name),
          trailing: _moving == s.bookingId
              ? const Text('Moving...')
              : PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'move') setState(() => _moving = s.bookingId);
                    if (v == 'cancel') _cancel(s, name);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'move', child: Text('Move to another time')),
                    PopupMenuItem(value: 'cancel', child: Text('Cancel booking')),
                  ],
                ),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.schedule),
        title: Text(time),
        subtitle: const Text('Free'),
        trailing: FilledButton(
          onPressed: () => _freeSlotTap(s),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          child: Text(_moving != null ? 'Move here' : 'Book member'),
        ),
      ),
    );
  }
}
