import 'package:flutter/material.dart';

import '../app.dart';
import '../shared/common.dart';
import '../shared/workout.dart';
import 'booking_events.dart';

/// Colours used for the marks on My calendar.
const coachColor = Color(0xFF34C759); // coach session: green
const workoutColor = Color(0xFFFF9500); // workout: orange
const gymColor = Color(0xFF3FA9F5); // gym time: blue

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

enum _Kind { coach, gym, workout }

class _Event {
  _Event(this.kind, this.day,
      {this.start, this.end, this.coach, this.status, this.group, this.planId,
      this.planned = 0, this.done = 0});
  final _Kind kind;
  final DateTime day;
  final DateTime? start;
  final DateTime? end;
  final String? coach;
  final String? status;
  final String? group; // muscle group name (workouts)
  final String? planId;
  final int planned;
  final int done;

  String get letter =>
      (group == null || group!.isEmpty) ? 'W' : group![0].toUpperCase();
}

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The member's own sessions, gym hours and workouts between [from] and [to]
/// (local midnights, [to] not included), grouped by day.
Future<Map<DateTime, List<_Event>>> _loadEvents(
    DateTime from, DateTime to) async {
  final uid = db.auth.currentUser!.id;
  final fromIso = from.toUtc().toIso8601String();
  final toIso = to.toUtc().toIso8601String();
  final res = await Future.wait<dynamic>([
    db
        .from('bookings')
        .select('id, status, slots!inner(starts_at, ends_at, coach_id)')
        .eq('member_id', uid)
        .neq('status', 'CANCELLED')
        .gte('slots.starts_at', fromIso)
        .lt('slots.starts_at', toIso),
    db
        .from('gym_bookings')
        .select('id, hour_start, status')
        .eq('member_id', uid)
        .neq('status', 'CANCELLED')
        .gte('hour_start', fromIso)
        .lt('hour_start', toIso),
    db
        .from('workout_plans')
        .select('id, plan_date, muscle_groups(name), '
            'workout_plan_exercises(target_sets, workout_set_logs(id))')
        .eq('member_id', uid)
        .gte('plan_date', isoDate(from))
        .lt('plan_date', isoDate(to)),
  ]);
  final bookings = (res[0] as List).cast<Map<String, dynamic>>();
  final gym = (res[1] as List).cast<Map<String, dynamic>>();
  final plans = (res[2] as List).cast<Map<String, dynamic>>();

  final coachIds = {
    for (final b in bookings) (b['slots'] as Map)['coach_id'] as String
  };
  final names = coachIds.isEmpty ? <String, String>{} : await nameMap(coachIds);

  final events = <_Event>[
    for (final b in bookings)
      () {
        final s = b['slots'] as Map;
        final start = DateTime.parse(s['starts_at'] as String).toLocal();
        return _Event(_Kind.coach, _dayOf(start),
            start: start,
            end: DateTime.parse(s['ends_at'] as String).toLocal(),
            coach: names[s['coach_id']],
            status: b['status'] as String);
      }(),
    for (final g in gym)
      () {
        final start = DateTime.parse(g['hour_start'] as String).toLocal();
        return _Event(_Kind.gym, _dayOf(start),
            start: start,
            end: start.add(const Duration(hours: 1)),
            status: g['status'] as String);
      }(),
    for (final p in plans)
      () {
        final ex = (p['workout_plan_exercises'] as List).cast<Map>();
        return _Event(_Kind.workout, DateTime.parse(p['plan_date'] as String),
            group: (p['muscle_groups'] as Map?)?['name'] as String?,
            planId: p['id'] as String,
            planned: ex.fold<int>(0, (s, e) => s + (e['target_sets'] as int)),
            done: ex.fold<int>(
                0, (s, e) => s + (e['workout_set_logs'] as List).length));
      }(),
  ];

  final byDay = <DateTime, List<_Event>>{};
  for (final e in events) {
    byDay.putIfAbsent(e.day, () => []).add(e);
  }
  // Timed items (sessions, gym) first by time, then workouts.
  for (final list in byDay.values) {
    list.sort((a, b) {
      if (a.start == null && b.start == null) return 0;
      if (a.start == null) return 1;
      if (b.start == null) return -1;
      return a.start!.compareTo(b.start!);
    });
  }
  return byDay;
}

/// Book > My calendar: the member's coach sessions (green), workouts (orange,
/// with the muscle group's first letter) and gym time (blue), by week or month.
class MyCalendarView extends StatefulWidget {
  const MyCalendarView({super.key});

  @override
  State<MyCalendarView> createState() => _MyCalendarViewState();
}

class _MyCalendarViewState extends State<MyCalendarView> {
  bool _monthView = true;
  late DateTime _anchor = _dayOf(DateTime.now()); // a day inside the period
  late DateTime _selected = _dayOf(DateTime.now());
  int _version = 0; // bumped to reload

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

  DateTime get _monday =>
      DateTime(_anchor.year, _anchor.month, _anchor.day - (_anchor.weekday - 1));

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
      final inPeriod = !today.isBefore(from) && today.isBefore(to) &&
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

  Future<void> _openWorkout(_Event e) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WorkoutPlanScreen(planId: e.planId!, canManage: false)));
    if (mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (from, to) = _range;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
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
                icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(_title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium),
            ),
            IconButton(
                onPressed: () => _step(1),
                icon: const Icon(Icons.chevron_right)),
          ],
        ),
        const _Legend(),
        Expanded(
          child: Loader<Map<DateTime, List<_Event>>>(
            key: ValueKey('${from.toIso8601String()}|$_monthView|$_version'),
            load: () => _loadEvents(from, to),
            builder: (context, byDay, reload) => _monthView
                ? _month(theme, byDay, from, to)
                : _week(theme, byDay, from),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- month

  Widget _month(ThemeData theme, Map<DateTime, List<_Event>> byDay,
      DateTime from, DateTime to) {
    final days = <DateTime>[
      for (var d = from; d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1))
        d
    ];
    final today = _dayOf(DateTime.now());
    final events = byDay[_selected] ?? const <_Event>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      children: [
        Row(children: [
          for (final w in weekdayNames)
            Expanded(
              child: Center(
                  child: Text(w,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.white54))),
            ),
        ]),
        const SizedBox(height: 4),
        for (var i = 0; i < days.length; i += 7)
          Row(children: [
            for (final d in days.sublist(i, i + 7))
              Expanded(
                child: _DayCell(
                  day: d,
                  events: byDay[d] ?? const [],
                  inMonth: d.month == _anchor.month,
                  isToday: _sameDay(d, today),
                  selected: _sameDay(d, _selected),
                  onTap: () => setState(() => _selected = d),
                ),
              ),
          ]),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
              '${weekdayNames[_selected.weekday - 1]} ${showDate(_selected)}',
              style: theme.textTheme.titleSmall),
        ),
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing booked or planned on this day.',
                style: TextStyle(color: Colors.white54)),
          ),
        for (final e in events) _eventTile(theme, e),
      ],
    );
  }

  // -------------------------------------------------------------- week

  Widget _week(
      ThemeData theme, Map<DateTime, List<_Event>> byDay, DateTime monday) {
    final today = _dayOf(DateTime.now());
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      children: [
        for (var i = 0; i < 7; i++)
          () {
            final d = DateTime(monday.year, monday.month, monday.day + i);
            final events = byDay[d] ?? const <_Event>[];
            final isToday = _sameDay(d, today);
            return Card(
              shape: isToday
                  ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: repLime))
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Row(children: [
                        Text('${weekdayNames[d.weekday - 1]} ${showDate(d)}',
                            style: theme.textTheme.titleSmall?.copyWith(
                                color: isToday ? repLime : null)),
                        const SizedBox(width: 8),
                        _Marks(events: events),
                      ]),
                    ),
                    if (events.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
                        child: Text('Nothing planned',
                            style: TextStyle(color: Colors.white38)),
                      ),
                    for (final e in events) _eventTile(theme, e, dense: true),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }

  // ------------------------------------------------------------- tiles

  Widget _eventTile(ThemeData theme, _Event e, {bool dense = false}) {
    final past = e.day.isBefore(_dayOf(DateTime.now()));
    switch (e.kind) {
      case _Kind.coach:
        return ListTile(
          dense: dense,
          leading: const _Badge(color: coachColor, icon: Icons.person),
          title: Text(
              'Coach session ${showTime(e.start!)}-${showTime(e.end!)}'),
          subtitle: Text([
            if (e.coach != null) 'Coach ${e.coach}',
            _statusText(e.status),
          ].join(' - ')),
        );
      case _Kind.gym:
        return ListTile(
          dense: dense,
          leading: const _Badge(color: gymColor, icon: Icons.fitness_center),
          title: Text('Gym time ${showTime(e.start!)}-${showTime(e.end!)}'),
          subtitle: Text(_statusText(e.status)),
        );
      case _Kind.workout:
        final progress = e.planned > 0 && e.done >= e.planned
            ? 'Done'
            : (e.done > 0
                ? '${e.done} of ${e.planned} sets done'
                : (past ? 'Not done' : 'Planned'));
        return ListTile(
          dense: dense,
          leading: _Badge(color: workoutColor, letter: e.letter),
          title: Text('${e.group ?? 'Workout'} workout'),
          subtitle: Text(progress),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openWorkout(e),
        );
    }
  }

  String _statusText(String? s) => switch (s) {
        'ATTENDED' => 'Checked in',
        'NO_SHOW' => 'Missed',
        _ => 'Booked',
      };
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.events,
    required this.inMonth,
    required this.isToday,
    required this.selected,
    required this.onTap,
  });
  final DateTime day;
  final List<_Event> events;
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
        height: 56,
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
              Text('${day.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isToday ? FontWeight.bold : null,
                      color: isToday ? repLime : null)),
              const SizedBox(height: 3),
              _Marks(events: events, small: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of marks for one day: green dot (coach session), orange circle with
/// the muscle group letter (workout), blue dot (gym time).
class _Marks extends StatelessWidget {
  const _Marks({required this.events, this.small = false});
  final List<_Event> events;
  final bool small;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return SizedBox(height: small ? 16 : 0);
    final dot = small ? 9.0 : 10.0;
    final ring = small ? 16.0 : 18.0;
    final marks = <Widget>[
      for (final _ in events.where((e) => e.kind == _Kind.coach))
        _dot(coachColor, dot),
      for (final e in events.where((e) => e.kind == _Kind.workout))
        Container(
          width: ring,
          height: ring,
          alignment: Alignment.center,
          decoration:
              const BoxDecoration(color: workoutColor, shape: BoxShape.circle),
          child: Text(e.letter,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                  color: Colors.black,
                  fontSize: small ? 10 : 11,
                  fontWeight: FontWeight.bold)),
        ),
      for (final _ in events.where((e) => e.kind == _Kind.gym))
        _dot(gymColor, dot),
    ];
    return SizedBox(
      height: ring,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < marks.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              marks[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c, double size) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, this.icon, this.letter});
  final Color color;
  final IconData? icon;
  final String? letter;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 16,
      backgroundColor: color,
      child: letter != null
          ? Text(letter!,
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.bold))
          : Icon(icon, size: 18, color: Colors.black),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    Widget item(Color c, String text, {String? letter}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: letter != null ? 14 : 9,
              height: letter != null ? 14 : 9,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              child: letter == null
                  ? null
                  : Text(letter,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 9,
                          fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 4),
            Text(text, style: style),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 4,
        children: [
          item(coachColor, 'Coach session'),
          item(workoutColor, 'Workout', letter: 'L'),
          item(gymColor, 'Gym time'),
        ],
      ),
    );
  }
}
