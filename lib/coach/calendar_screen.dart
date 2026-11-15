import 'package:flutter/material.dart';

import '../app.dart';
import '../shared/common.dart';
import '../shared/session_length.dart';
import '../shared/workout.dart' show weekdayNames;
import 'members_screen.dart' show CoachMemberDetail;

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// One booked appointment in one of the coach's sessions.
class _Appt {
  _Appt(
    this.bookingId,
    this.start,
    this.end,
    this.memberId,
    this.memberName,
    this.status,
  );
  final String bookingId;
  final DateTime start;
  final DateTime end;
  final String memberId;
  final String memberName;
  final String status;
}

/// The coach's own bookings between [from] and [to] (local midnights, [to]
/// not included), grouped by day and sorted by time.
Future<Map<DateTime, List<_Appt>>> _loadAppts(
  DateTime from,
  DateTime to,
) async {
  final slots =
      await db
              .from('slots')
              .select('starts_at, ends_at, bookings(id, status, member_id)')
              .eq('coach_id', db.auth.currentUser!.id)
              .eq('is_cancelled', false)
              .gte('starts_at', from.toUtc().toIso8601String())
              .lt('starts_at', to.toUtc().toIso8601String())
              .order('starts_at', ascending: true)
          as List;
  final ids = <String>{
    for (final s in slots)
      for (final b in (s['bookings'] as List))
        if (b['status'] != 'CANCELLED') b['member_id'] as String,
  };
  final names = ids.isEmpty ? <String, String>{} : await nameMap(ids);
  final byDay = <DateTime, List<_Appt>>{};
  for (final s in slots) {
    final start = DateTime.parse(s['starts_at'] as String).toLocal();
    final end = DateTime.parse(s['ends_at'] as String).toLocal();
    for (final b in (s['bookings'] as List)) {
      if (b['status'] == 'CANCELLED') continue;
      final id = b['member_id'] as String;
      byDay
          .putIfAbsent(_dayOf(start), () => [])
          .add(
            _Appt(
              b['id'] as String,
              start,
              end,
              id,
              names[id] ?? 'Member',
              b['status'] as String,
            ),
          );
    }
  }
  for (final list in byDay.values) {
    list.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : a.memberName.toLowerCase().compareTo(b.memberName.toLowerCase()),
    );
  }
  return byDay;
}

/// Coach > Calendar: week or month view of the coach's own bookings. Each day
/// shows how many members are booked; the chosen day's appointments are
/// listed underneath.
class CoachCalendarScreen extends StatefulWidget {
  const CoachCalendarScreen({super.key});

  @override
  State<CoachCalendarScreen> createState() => _CoachCalendarScreenState();
}

class _CoachCalendarScreenState extends State<CoachCalendarScreen> {
  bool _monthView = true;
  late DateTime _anchor = _dayOf(DateTime.now()); // a day inside the period
  late DateTime _selected = _dayOf(DateTime.now());
  int _version = 0; // bumped to reload

  DateTime get _monday => DateTime(
    _anchor.year,
    _anchor.month,
    _anchor.day - (_anchor.weekday - 1),
  );

  /// First and last+1 day shown (whole weeks, Monday first).
  (DateTime, DateTime) get _range {
    if (!_monthView) {
      final m = _monday;
      return (m, DateTime(m.year, m.month, m.day + 7));
    }
    final first = DateTime(_anchor.year, _anchor.month, 1);
    final last = DateTime(_anchor.year, _anchor.month + 1, 0);
    return (
      DateTime(first.year, first.month, first.day - (first.weekday - 1)),
      DateTime(last.year, last.month, last.day + (7 - last.weekday) + 1),
    );
  }

  String get _title {
    if (_monthView) return '${_months[_anchor.month - 1]} ${_anchor.year}';
    final m = _monday;
    final s = DateTime(m.year, m.month, m.day + 6);
    return '${two(m.day)}/${two(m.month)} - ${two(s.day)}/${two(s.month)}/${s.year}';
  }

  void _step(int dir) {
    setState(() {
      if (_monthView) {
        _anchor = DateTime(_anchor.year, _anchor.month + dir, 1);
      } else {
        final m = _monday;
        _anchor = DateTime(m.year, m.month, m.day + 7 * dir);
      }
      final (from, to) = _range;
      final today = _dayOf(DateTime.now());
      final inPeriod =
          !today.isBefore(from) &&
          today.isBefore(to) &&
          (!_monthView || today.month == _anchor.month);
      _selected = inPeriod ? today : (_monthView ? _anchor : _monday);
    });
  }

  void _goToday() {
    setState(() {
      _anchor = _dayOf(DateTime.now());
      _selected = _anchor;
    });
  }

  Future<void> _openMember(_Appt a) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CoachMemberDetail(id: a.memberId, name: a.memberName),
      ),
    );
    if (mounted) setState(() => _version++);
  }

  /// Any booked session can be marked as a no-show, also before it starts
  /// (member away without telling; needs db/28). 1 credit is taken at once.
  Future<void> _noShow(_Appt a) async {
    final ahead = DateTime.now().isBefore(a.start);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as no-show?'),
        content: Text(
          '${a.memberName} will lose 1 credit for the '
          '${showTime(a.start)} session on ${showDate(a.start)}.'
          '${ahead ? '\n\nThis session has not happened yet. The credit is '
                    'taken now and the session stays blocked.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('No-show'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('mark_no_show', params: {'p_booking': a.bookingId});
    });
    if (ok && mounted) setState(() => _version++);
  }

  /// Move a booking to another free session of this coach (same DB rules as
  /// the Schedule tab: 12-hour lock, 30-minute bookings stay 30 minutes).
  Future<void> _reschedule(_Appt a) async {
    final half = isHalfHour(a.start, a.end);
    final target = await Navigator.of(context)
        .push<_Free>(MaterialPageRoute(builder: (_) => _MovePicker(appt: a)));
    if (target == null || !mounted) return;
    DateTime? newStart;
    if (half && !isHalfHour(target.start, target.end)) {
      newStart = await pickHalf(context, target.start);
      if (newStart == null || !mounted) return;
    }
    final when = newStart ?? target.start;
    final whenEnd = newStart != null ? newStart.add(halfHour) : target.end;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reschedule session?'),
        content: Text(
          'Move ${a.memberName} from ${weekdayNames[a.start.weekday - 1]} '
          '${showDate(a.start)} ${showTime(a.start)} to '
          '${weekdayNames[when.weekday - 1]} ${showDate(when)} '
          '${showTime(when)}-${showTime(whenEnd)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc(
        'reschedule_booking',
        params: {
          'p_booking': a.bookingId,
          'p_new_slot': target.id,
          if (newStart != null)
            'p_new_start': newStart.toUtc().toIso8601String(),
        },
      );
    });
    if (!ok || !mounted) return;
    snack(context, 'Session moved');
    setState(() {
      _selected = _dayOf(when);
      _anchor = _selected;
      _version++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (from, to) = _range;
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Week')),
                    ButtonSegment(value: true, label: Text('Month')),
                  ],
                  selected: {_monthView},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() {
                    _monthView = v.first;
                    _anchor = _selected;
                  }),
                ),
                const Spacer(),
                TextButton(onPressed: _goToday, child: const Text('Today')),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () => _step(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  _title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: () => _step(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Expanded(
            child: Loader<Map<DateTime, List<_Appt>>>(
              key: ValueKey('${from.toIso8601String()}|$_monthView|$_version'),
              load: () => _loadAppts(from, to),
              builder: (context, byDay, reload) =>
                  _body(theme, byDay, from, to),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    ThemeData theme,
    Map<DateTime, List<_Appt>> byDay,
    DateTime from,
    DateTime to,
  ) {
    final days = <DateTime>[
      for (
        var d = from;
        d.isBefore(to);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        d,
    ];
    final today = _dayOf(DateTime.now());
    final appts = byDay[_selected] ?? const <_Appt>[];
    final total = byDay.entries
        .where((e) => !_monthView || e.key.month == _anchor.month)
        .fold<int>(0, (s, e) => s + e.value.length);
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        Row(
          children: [
            for (final w in weekdayNames)
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < days.length; i += 7)
          Row(
            children: [
              for (final d in days.sublist(i, i + 7))
                Expanded(
                  child: _DayCell(
                    day: d,
                    count: byDay[d]?.length ?? 0,
                    inMonth: !_monthView || d.month == _anchor.month,
                    isToday: _sameDay(d, today),
                    selected: _sameDay(d, _selected),
                    onTap: () => setState(() => _selected = d),
                  ),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Text(
            '$total ${total == 1 ? 'booking' : 'bookings'} this '
            '${_monthView ? 'month' : 'week'}',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white54),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${weekdayNames[_selected.weekday - 1]} ${showDate(_selected)}'
            '${appts.isEmpty ? '' : '  ·  ${appts.length} booked'}',
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (appts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No bookings on this day.',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        for (final a in appts) _tile(theme, a),
      ],
    );
  }

  Widget _tile(ThemeData theme, _Appt a) {
    final (label, color) = switch (a.status) {
      'ATTENDED' => ('Checked in', repLime),
      'NO_SHOW' => ('No-show', theme.colorScheme.error),
      _ => ('Booked', Colors.white70),
    };
    final mins = a.end.difference(a.start).inMinutes;
    final booked = a.status == 'BOOKED';
    final upcoming = DateTime.now().isBefore(a.start);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: SizedBox(
              width: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    showTime(a.start),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    mins == 30 ? '30 min' : showTime(a.end),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            title: Text(a.memberName),
            subtitle: Text(label, style: TextStyle(color: color)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openMember(a),
          ),
          if (booked)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (upcoming)
                    TextButton.icon(
                      onPressed: () => _reschedule(a),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('Reschedule'),
                    ),
                  TextButton.icon(
                    onPressed: () => _noShow(a),
                    icon: Icon(
                      Icons.person_off_outlined,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    label: Text(
                      'Mark no-show',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A free session of this coach that a booking can move to.
class _Free {
  _Free(this.id, this.start, this.end);
  final String id;
  final DateTime start;
  final DateTime end;
}

/// Lists the coach's free sessions for the next 4 weeks; tap one to choose it.
/// A 1-hour booking only sees 1-hour sessions; a 30-minute booking sees both
/// (a free hour is split into halves after picking).
class _MovePicker extends StatelessWidget {
  const _MovePicker({required this.appt});
  final _Appt appt;

  Future<List<_Free>> _load() async {
    final now = DateTime.now();
    final to = DateTime(now.year, now.month, now.day + 28);
    final rows =
        await db
                .from('slots')
                .select('id, starts_at, ends_at, bookings(status)')
                .eq('coach_id', db.auth.currentUser!.id)
                .eq('is_cancelled', false)
                .gte('starts_at', now.toUtc().toIso8601String())
                .lt('starts_at', to.toUtc().toIso8601String())
                .order('starts_at', ascending: true)
            as List;
    final half = isHalfHour(appt.start, appt.end);
    return [
          for (final r in rows)
            if (!(r['bookings'] as List).any((b) => b['status'] != 'CANCELLED'))
              _Free(
                r['id'] as String,
                DateTime.parse(r['starts_at'] as String).toLocal(),
                DateTime.parse(r['ends_at'] as String).toLocal(),
              ),
        ]
        .where((s) => half || !isHalfHour(s.start, s.end))
        .where((s) => s.start != appt.start)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Move ${appt.memberName}')),
      body: Loader<List<_Free>>(
        load: _load,
        builder: (context, free, reload) {
          if (free.isEmpty) {
            return ListView(
              children: const [
                SizedBox(height: 80),
                Center(child: Text('No free sessions in the next 4 weeks.')),
              ],
            );
          }
          final children = <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Text(
                'Now: ${weekdayNames[appt.start.weekday - 1]} '
                '${showDate(appt.start)} ${showTime(appt.start)}-'
                '${showTime(appt.end)}. Choose a free session:',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ];
          DateTime? day;
          for (final s in free) {
            final d = _dayOf(s.start);
            if (day != d) {
              day = d;
              children.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                  child: Text(
                    '${weekdayNames[d.weekday - 1]} ${showDate(d)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              );
            }
            final tag = lengthTag(s.start, s.end);
            children.add(
              Card(
                child: ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(
                    '${showTime(s.start)} - ${showTime(s.end)}'
                    '${tag.isEmpty ? '' : '  ($tag)'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pop(s),
                ),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.all(8), children: children);
        },
      ),
    );
  }
}

/// A day in the grid: the date, and a lime badge with the number of bookings.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.count,
    required this.inMonth,
    required this.isToday,
    required this.selected,
    required this.onTap,
  });
  final DateTime day;
  final int count;
  final bool inMonth;
  final bool isToday;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 58,
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: selected ? repLime.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: repLime) : null,
        ),
        child: Opacity(
          opacity: inMonth ? 1 : 0.35,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isToday ? FontWeight.bold : null,
                  color: isToday ? repLime : null,
                ),
              ),
              const SizedBox(height: 3),
              SizedBox(
                height: 20,
                child: count == 0
                    ? null
                    : Container(
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: repLime,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            '$count',
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
