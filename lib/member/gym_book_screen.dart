import 'package:flutter/material.dart';

import '../shared/common.dart';
import 'booking_events.dart';
import 'book_screen.dart';
import 'coach_week_screen.dart';
import 'my_calendar_screen.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _daysAhead = 14;

/// The Book tab. A member with a coach books coach sessions, a member with a
/// Monthly Pass books gym hours, and a member with both gets two tabs.
class BookHub extends StatelessWidget {
  const BookHub({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader<({bool coach, bool pass})>(
      load: () async {
        final uid = db.auth.currentUser!.id;
        final mp = await db
            .from('member_profiles')
            .select('primary_coach_id')
            .eq('id', uid)
            .maybeSingle();
        final pass = await db
            .from('member_packages')
            .select('id')
            .eq('member_id', uid)
            .eq('kind', 'PASS')
            .eq('status', 'ACTIVE')
            .limit(1);
        return (coach: mp?['primary_coach_id'] != null, pass: pass.isNotEmpty);
      },
      builder: (context, who, reload) {
        // A coach gives access to gym time as well as a Monthly Pass.
        if (who.coach) {
          return DefaultTabController(
            length: 4,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Book'),
                bottom: const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'My calendar'),
                      Tab(text: 'Coach sessions'),
                      Tab(text: 'Coach week'),
                      Tab(text: 'Gym time'),
                    ]),
              ),
              body: const TabBarView(children: [
                MyCalendarView(),
                BookScreen(embedded: true),
                CoachWeekView(),
                GymBookView(),
              ]),
            ),
          );
        }
        if (who.pass) {
          return DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Book'),
                bottom: const TabBar(
                    tabs: [Tab(text: 'My calendar'), Tab(text: 'Gym time')]),
              ),
              body: const TabBarView(children: [
                MyCalendarView(),
                GymBookView(),
              ]),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Book')),
          body: ListView(children: const [
            SizedBox(height: 120),
            Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                  'You need a Monthly Pass or a coach to book. Please contact the gym.',
                  textAlign: TextAlign.center),
            ),
          ]),
        );
      },
    );
  }
}

class _Hour {
  _Hour(Map<String, dynamic> r)
      : start = DateTime.parse(r['hour_start'] as String).toLocal(),
        taken = r['taken'] as int,
        capacity = r['capacity'] as int,
        myBooking = r['my_booking'] as String?,
        myStatus = r['my_status'] as String?;
  final DateTime start;
  final int taken;
  final int capacity;
  final String? myBooking;
  final String? myStatus;
  bool get full => taken >= capacity;
}

Future<List<_Hour>> _loadHours() async {
  final now = DateTime.now();
  final to = DateTime(now.year, now.month, now.day + _daysAhead);
  final rows = await db.rpc('gym_hours', params: {
    'p_from': now.toUtc().toIso8601String(),
    'p_to': to.toUtc().toIso8601String(),
  }) as List;
  return [for (final r in rows) _Hour(Map<String, dynamic>.from(r as Map))];
}

class GymBookView extends StatefulWidget {
  const GymBookView({super.key});

  @override
  State<GymBookView> createState() => _GymBookViewState();
}

class _GymBookViewState extends State<GymBookView> {
  final _loader = GlobalKey<LoaderState<List<_Hour>>>();
  late DateTime _day = _today();

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _reload() async => _loader.currentState?.reload();

  void _changed() => _reload();

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

  String _label(_Hour h) =>
      '${_weekdays[h.start.weekday - 1]} ${showDate(h.start)}, ${showTime(h.start)}-${showTime(h.start.add(const Duration(hours: 1)))}';

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

  Future<void> _book(_Hour h) async {
    if (!await _confirm('Book gym time', 'Book ${_label(h)}?', 'Book')) return;
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('book_gym_hour',
          params: {'p_hour': h.start.toUtc().toIso8601String()});
    });
    if (ok) {
      if (mounted) snack(context, 'Gym time booked');
      notifyBookingsChanged();
    }
  }

  Future<void> _cancel(_Hour h) async {
    if (!await _confirm(
        'Cancel gym time', 'Cancel ${_label(h)}?', 'Cancel booking')) {
      return;
    }
    if (!mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('cancel_gym_booking', params: {'p_booking': h.myBooking});
    });
    if (ok) {
      if (mounted) snack(context, 'Booking cancelled');
      notifyBookingsChanged();
    }
  }

  void _who(_Hour h) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PresenceSheet(hour: h.start, title: _label(h)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = _today();
    final days = [
      for (var i = 0; i < _daysAhead; i++)
        DateTime(today.year, today.month, today.day + i)
    ];
    return Column(
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
        Expanded(
          child: Loader<List<_Hour>>(
            key: _loader,
            load: _loadHours,
            builder: (context, all, reload) {
              final hours = all.where((h) => _sameDay(h.start, _day)).toList();
              if (hours.isEmpty) {
                return ListView(children: const [
                  SizedBox(height: 80),
                  Center(child: Text('The gym is closed on this day')),
                ]);
              }
              return ListView(
                padding: const EdgeInsets.all(12),
                children: [for (final h in hours) _tile(theme, h)],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tile(ThemeData theme, _Hour h) {
    final time =
        '${showTime(h.start)} - ${showTime(h.start.add(const Duration(hours: 1)))}';
    final mine = h.myBooking != null;
    final checkedIn = h.myStatus == 'ATTENDED';
    return Card(
      color: mine ? theme.colorScheme.primary.withValues(alpha: 0.15) : null,
      child: ListTile(
        leading: Icon(
            mine
                ? Icons.event_available
                : (h.full ? Icons.lock_outline : Icons.schedule),
            color: mine ? theme.colorScheme.primary : null),
        title: Text(time),
        subtitle: Text(mine
            ? (checkedIn ? 'Checked in' : 'Your booking')
            : (h.full
                ? 'Full (${h.taken} of ${h.capacity})'
                : '${h.taken} of ${h.capacity} places taken')),
        onTap: () => _who(h),
        trailing: mine
            ? (checkedIn
                ? null
                : TextButton(
                    onPressed: () => _cancel(h), child: const Text('Cancel')))
            : (h.full
                ? null
                : FilledButton(
                    onPressed: () => _book(h),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40)),
                    child: const Text('Book'),
                  )),
      ),
    );
  }
}

class _PresenceSheet extends StatelessWidget {
  const _PresenceSheet({required this.hour, required this.title});
  final DateTime hour;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Who is in the gym', style: theme.textTheme.titleMedium),
              Text(title, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Flexible(
                child: FutureBuilder<List<dynamic>>(
                  future: db.rpc('gym_presence', params: {
                    'p_hour': hour.toUtc().toIso8601String()
                  }).then((v) => v as List),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const Text(
                          'Only gym members can see this list.');
                    }
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final rows = snap.data!;
                    if (rows.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('Nobody has booked this hour yet.'),
                      );
                    }
                    return ListView(shrinkWrap: true, children: [
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          leading: Icon(
                              r['state'] == 'CHECKED_IN'
                                  ? Icons.check_circle
                                  : Icons.schedule,
                              color: r['state'] == 'CHECKED_IN'
                                  ? theme.colorScheme.primary
                                  : null),
                          title: Text(r['who'] as String),
                          trailing: Text(r['state'] == 'CHECKED_IN'
                              ? 'Checked in'
                              : 'Booked'),
                        ),
                    ]);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
