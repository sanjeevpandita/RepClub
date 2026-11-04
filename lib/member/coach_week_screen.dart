import 'package:flutter/material.dart';

import '../app.dart';
import '../shared/common.dart';
import '../shared/workout.dart' show weekdayNames;
import 'booking_events.dart';
import 'my_calendar_screen.dart' show coachColor;

const _weeksAhead = 5; // how many weeks after this one can be shown

class _Slot {
  _Slot(this.id, this.start, this.end, this.taken);
  final String id;
  final DateTime start;
  final DateTime end;
  final bool taken;
}

class _WeekData {
  _WeekData(this.slots, this.mine, this.coach, this.canSelfBook);
  final List<_Slot> slots;
  final Map<String, ({String id, String status})> mine; // slot id -> own booking
  final String coach;
  final bool canSelfBook;
}

DateTime _mondayOf(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

Future<_WeekData> _load(DateTime monday) async {
  final uid = db.auth.currentUser!.id;
  final to = DateTime(monday.year, monday.month, monday.day + 7);
  final rows = await db.rpc('member_slots', params: {
    'p_from': monday.toUtc().toIso8601String(),
    'p_to': to.toUtc().toIso8601String(),
  }) as List;
  final slots = [
    for (final r in rows)
      _Slot(
        r['slot_id'] as String,
        DateTime.parse(r['starts_at'] as String).toLocal(),
        DateTime.parse(r['ends_at'] as String).toLocal(),
        r['is_taken'] as bool,
      ),
  ];
  final mp = await db
      .from('member_profiles')
      .select('primary_coach_id, can_self_book')
      .eq('id', uid)
      .maybeSingle();
  final coachId = mp?['primary_coach_id'] as String?;
  final coach =
      coachId == null ? '' : (await nameMap([coachId]))[coachId] ?? '';
  final own = slots.isEmpty
      ? const []
      : await db
          .from('bookings')
          .select('id, slot_id, status')
          .eq('member_id', uid)
          .neq('status', 'CANCELLED')
          .inFilter('slot_id', [for (final s in slots) s.id]) as List;
  return _WeekData(
    slots,
    {
      for (final b in own)
        b['slot_id'] as String: (id: b['id'] as String, status: b['status'] as String)
    },
    coach,
    mp?['can_self_book'] != false,
  );
}

/// Book > Coach week: the coach's sessions for one week as a grid, each one
/// OPEN, BOOKED (by someone else, no name shown) or YOU. Tap OPEN to book or
/// to move your booking there; tap YOU to move or cancel.
class CoachWeekView extends StatefulWidget {
  const CoachWeekView({super.key});

  @override
  State<CoachWeekView> createState() => _CoachWeekViewState();
}

class _CoachWeekViewState extends State<CoachWeekView> {
  final DateTime _thisMonday = _mondayOf(DateTime.now());
  late DateTime _monday = _thisMonday;
  String? _moving; // own booking id being moved
  int _version = 0;

  @override
  void initState() {
    super.initState();
    bookingsChanged.addListener(_changed);
  }

  @override
  void dispose() {
    bookingsChanged.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() => _version++);
  }

  int get _weekIndex => _monday.difference(_thisMonday).inDays ~/ 7;

  void _step(int dir) => setState(() =>
      _monday = DateTime(_monday.year, _monday.month, _monday.day + 7 * dir));

  String _label(_Slot s) =>
      '${weekdayNames[s.start.weekday - 1]} ${showDate(s.start)}, ${showTime(s.start)}-${showTime(s.end)}';

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

  Future<void> _tapOpen(_Slot s, _WeekData data) async {
    if (_moving != null) {
      if (!await _confirm(
          'Move session', 'Move your booking to ${_label(s)}?', 'Move')) {
        return;
      }
      if (!mounted) return;
      final id = _moving!;
      final ok = await attempt(context, () async {
        await db.rpc('reschedule_booking',
            params: {'p_booking': id, 'p_new_slot': s.id});
      });
      if (ok) {
        _moving = null;
        if (mounted) snack(context, 'Session moved');
        notifyBookingsChanged();
      }
      return;
    }
    if (!data.canSelfBook) {
      snack(context,
          'Your coach books your sessions. Ask your coach to book this one.');
      return;
    }
    if (!await _confirm('Book session', 'Book ${_label(s)}?', 'Book')) return;
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('create_booking', params: {'p_slot': s.id});
    });
    if (ok) {
      if (mounted) snack(context, 'Session booked');
      notifyBookingsChanged();
    }
  }

  Future<void> _tapMine(_Slot s, String bookingId) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Your session'),
              subtitle: Text(_label(s)),
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Move to another time'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.event_busy),
              title: const Text('Cancel booking'),
              onTap: () => Navigator.pop(ctx, 'cancel'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'move') {
      setState(() => _moving = bookingId);
    } else if (choice == 'cancel') {
      if (!await _confirm(
          'Cancel booking',
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
        notifyBookingsChanged();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sunday = DateTime(_monday.year, _monday.month, _monday.day + 6);
    return Column(
      children: [
        Row(
          children: [
            IconButton(
                onPressed: _weekIndex > 0 ? () => _step(-1) : null,
                icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(
                '${_weekIndex == 0 ? 'This week' : (_weekIndex == 1 ? 'Next week' : 'Week of')}  '
                '${two(_monday.day)}/${two(_monday.month)} - ${two(sunday.day)}/${two(sunday.month)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
                onPressed: _weekIndex < _weeksAhead ? () => _step(1) : null,
                icon: const Icon(Icons.chevron_right)),
          ],
        ),
        if (_moving != null)
          MaterialBanner(
            content: const Text('Tap an OPEN session to move your booking.'),
            actions: [
              TextButton(
                  onPressed: () => setState(() => _moving = null),
                  child: const Text('Stop moving')),
            ],
          ),
        Expanded(
          child: Loader<_WeekData>(
            key: ValueKey('${_monday.toIso8601String()}|$_version'),
            load: () => _load(_monday),
            builder: (context, data, reload) => _grid(theme, data),
          ),
        ),
      ],
    );
  }

  Widget _grid(ThemeData theme, _WeekData data) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (var i = 0; i < 7; i++)
        DateTime(_monday.year, _monday.month, _monday.day + i)
    ];
    // Each distinct start time is one row.
    final times = {for (final s in data.slots) showTime(s.start)}.toList()
      ..sort();
    final cell = <String, _Slot>{
      for (final s in data.slots)
        '${s.start.weekday}|${showTime(s.start)}': s,
    };

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.coach.isNotEmpty)
            Text('Coach ${data.coach}', style: theme.textTheme.titleSmall),
          Text(
            data.canSelfBook
                ? 'Tap OPEN to book. Tap YOU to move or cancel.'
                : 'Your coach books your sessions. Tap YOU to move or cancel.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 12, children: [
            _legend('OPEN', _CellStyle.open),
            _legend('BOOKED', _CellStyle.taken),
            _legend('YOU', _CellStyle.mine),
          ]),
        ],
      ),
    );

    if (times.isEmpty) {
      return ListView(children: [
        header,
        const SizedBox(height: 60),
        const Center(child: Text('Your coach has no sessions this week')),
      ]);
    }

    return LayoutBuilder(builder: (context, box) {
      const timeW = 44.0;
      const rowH = 40.0;
      final cellW = (box.maxWidth - 16 - timeW) / 7;
      return ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          header,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: timeW),
                for (final d in days)
                  SizedBox(
                    width: cellW,
                    child: Column(children: [
                      Text(weekdayNames[d.weekday - 1],
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: d == today ? repLime : Colors.white60)),
                      Text('${d.day}',
                          style: theme.textTheme.titleSmall?.copyWith(
                              color: d == today ? repLime : null)),
                    ]),
                  ),
              ]),
              const SizedBox(height: 4),
              for (final t in times)
                Row(children: [
                  SizedBox(
                    width: timeW,
                    height: rowH,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(t, style: theme.textTheme.labelSmall),
                    ),
                  ),
                  for (final d in days)
                    SizedBox(
                      width: cellW,
                      height: rowH,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: _cell(cell['${d.weekday}|$t'], data, now),
                      ),
                    ),
                ]),
            ]),
          ),
        ],
      );
    });
  }

  Widget _cell(_Slot? s, _WeekData data, DateTime now) {
    if (s == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    final past = !s.start.isAfter(now);
    final mine = data.mine[s.id];
    final _CellStyle style;
    final String text;
    VoidCallback? onTap;
    if (mine != null) {
      style = _CellStyle.mine;
      text = _moving == mine.id ? 'MOVING' : 'YOU';
      if (!past && mine.status == 'BOOKED' && _moving == null) {
        onTap = () => _tapMine(s, mine.id);
      }
    } else if (s.taken) {
      style = _CellStyle.taken;
      text = 'BOOKED';
    } else {
      style = _CellStyle.open;
      text = 'OPEN';
      if (!past) onTap = () => _tapOpen(s, data);
    }
    return Opacity(
      opacity: past ? 0.35 : 1,
      child: Material(
        color: style.fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: style.border == null
              ? BorderSide.none
              : BorderSide(color: style.border!),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(text,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: style.text)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _legend(String text, _CellStyle s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: s.fill,
          borderRadius: BorderRadius.circular(6),
          border: s.border == null ? null : Border.all(color: s.border!),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: s.text)),
      );
}

class _CellStyle {
  const _CellStyle(this.fill, this.text, this.border);
  final Color fill;
  final Color text;
  final Color? border;

  static const open = _CellStyle(Colors.transparent, repLime, repLime);
  static const taken = _CellStyle(repCharcoal, Colors.white54, null);
  static const mine = _CellStyle(coachColor, Colors.black, null);
}
