import 'package:flutter/material.dart';

import '../shared/common.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _daysAhead = 14;

class _Slot {
  _Slot(this.id, this.start, this.end, this.taken);
  final String id;
  final DateTime start;
  final DateTime end;
  final bool taken;
}

class _BookData {
  _BookData(this.slots, this.mine, this.coach, this.canSelfBook);
  final List<_Slot> slots;
  final Map<String, String> mine; // slot id -> booking id (own, still booked)
  final String coach;
  final bool canSelfBook;
}

Future<_BookData> _load() async {
  final uid = db.auth.currentUser!.id;
  final now = DateTime.now();
  final to = DateTime(now.year, now.month, now.day + _daysAhead);
  final rows = await db.rpc('member_slots', params: {
    'p_from': now.toUtc().toIso8601String(),
    'p_to': to.toUtc().toIso8601String(),
  }) as List;
  final mp = await db
      .from('member_profiles')
      .select('primary_coach_id, can_self_book')
      .eq('id', uid)
      .maybeSingle();
  final coachId = mp?['primary_coach_id'] as String?;
  final coach =
      coachId == null ? '' : (await nameMap([coachId]))[coachId] ?? '';
  final bookings = await db
      .from('bookings')
      .select('id, slot_id')
      .eq('member_id', uid)
      .eq('status', 'BOOKED') as List;
  return _BookData(
    [
      for (final r in rows)
        _Slot(
          r['slot_id'] as String,
          DateTime.parse(r['starts_at'] as String).toLocal(),
          DateTime.parse(r['ends_at'] as String).toLocal(),
          r['is_taken'] as bool,
        ),
    ],
    {for (final b in bookings) b['slot_id'] as String: b['id'] as String},
    coach,
    mp?['can_self_book'] != false,
  );
}

class BookScreen extends StatefulWidget {
  const BookScreen({super.key, this.embedded = false});

  /// True when shown inside a tab of another screen (no app bar of its own).
  final bool embedded;

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  final _loader = GlobalKey<LoaderState<_BookData>>();
  late DateTime _day = _today();
  String? _moving; // booking id being moved

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _reload() async => _loader.currentState?.reload();

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

  String _label(_Slot s) =>
      '${_weekdays[s.start.weekday - 1]} ${showDate(s.start)}, ${showTime(s.start)}-${showTime(s.end)}';

  Future<void> _book(_Slot s) async {
    if (_moving != null) {
      if (!await _confirm('Move session', 'Move your booking to ${_label(s)}?',
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
    if (!await _confirm('Book session', 'Book ${_label(s)}?', 'Book')) return;
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('create_booking', params: {'p_slot': s.id});
    });
    if (ok) {
      if (mounted) snack(context, 'Session booked');
      await _reload();
    }
  }

  Future<void> _cancel(_Slot s, String bookingId) async {
    if (!await _confirm('Cancel booking',
        'Cancel ${_label(s)}? Sessions within 12 hours cannot be cancelled.',
        'Cancel booking')) {
      return;
    }
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('cancel_booking', params: {'p_booking': bookingId});
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
      appBar:
          widget.embedded ? null : AppBar(title: const Text('Book a session')),
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
                final sel = _sameDay(d, _day);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    selected: sel,
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
              content: const Text('Choose a new time for your session.'),
              actions: [
                TextButton(
                    onPressed: () => setState(() => _moving = null),
                    child: const Text('Stop moving')),
              ],
            ),
          Expanded(
            child: Loader<_BookData>(
              key: _loader,
              load: _load,
              builder: (context, data, reload) {
                final slots =
                    data.slots.where((s) => _sameDay(s.start, _day)).toList();
                final banner = data.canSelfBook
                    ? const SizedBox.shrink()
                    : const Card(
                        child: ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('Your coach books your sessions'),
                          subtitle: Text(
                              'Ask your coach to book or change a session for you.'),
                        ),
                      );
                if (slots.isEmpty) {
                  return ListView(padding: const EdgeInsets.all(12), children: [
                    banner,
                    const SizedBox(height: 80),
                    const Center(child: Text('No sessions on this day')),
                  ]);
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    banner,
                    for (final s in slots) _tile(context, s, data),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, _Slot s, _BookData data) {
    final theme = Theme.of(context);
    final bookingId = data.mine[s.id];
    final time = '${showTime(s.start)} - ${showTime(s.end)}';
    if (bookingId != null) {
      return Card(
        color: theme.colorScheme.primary.withValues(alpha: 0.15),
        child: ListTile(
          leading: Icon(Icons.event_available, color: theme.colorScheme.primary),
          title: Text(time),
          subtitle: Text(
              data.coach.isEmpty ? 'Your booking' : 'Your booking - Coach ${data.coach}'),
          trailing: _moving == bookingId
              ? const Text('Moving...')
              : PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'move') setState(() => _moving = bookingId);
                    if (v == 'cancel') _cancel(s, bookingId);
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
        leading: Icon(s.taken ? Icons.lock_outline : Icons.schedule),
        title: Text(time),
        subtitle: Text(
            '${s.taken ? 'Taken' : 'Available'}${data.coach.isEmpty ? '' : ' - Coach ${data.coach}'}'),
        enabled: !s.taken,
        trailing: s.taken || (!data.canSelfBook && _moving == null)
            ? null
            : FilledButton(
                onPressed: () => _book(s),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                child: Text(_moving != null ? 'Move here' : 'Book'),
              ),
      ),
    );
  }
}
