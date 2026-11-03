import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/common.dart';
import 'members_screen.dart' show CoachMemberDetail;

class _Row {
  _Row(this.startsAt, this.endsAt, this.memberName, this.bookingId, this.status);
  final DateTime startsAt;
  final DateTime endsAt;
  final String memberName;
  final String bookingId;
  final String status;
}

/// Coach's sessions for a day: who is booked, attended, no-show.
class CoachTodayScreen extends StatefulWidget {
  const CoachTodayScreen({super.key});

  @override
  State<CoachTodayScreen> createState() => _CoachTodayScreenState();
}

class _CoachTodayScreenState extends State<CoachTodayScreen> {
  List<_Row>? _rows;
  List<({String id, String name, int credits})> _low = [];
  String? _error;
  Timer? _timer;
  DateTime _day = _dateOnly(DateTime.now());

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  bool get _isToday => _day == _dateOnly(DateTime.now());

  void _goTo(DateTime d) {
    setState(() {
      _day = _dateOnly(d);
      _rows = null;
    });
    _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final day = _day;
      final start = DateTime(day.year, day.month, day.day);
      final end = DateTime(day.year, day.month, day.day + 1);
      final slots = await db
          .from('slots')
          .select('id, starts_at, ends_at, bookings(id, status, member_id)')
          .eq('coach_id', db.auth.currentUser!.id)
          .eq('is_cancelled', false)
          .gte('starts_at', start.toUtc().toIso8601String())
          .lt('starts_at', end.toUtc().toIso8601String())
          .order('starts_at');
      final ids = <String>{
        for (final s in slots)
          for (final b in (s['bookings'] as List))
            if (b['status'] != 'CANCELLED') b['member_id'] as String
      };
      final names = ids.isEmpty ? <String, String>{} : await nameMap(ids);
      // Own members whose active package is down to the low-credit limit.
      final mine = await db
          .from('member_profiles')
          .select('id')
          .eq('primary_coach_id', db.auth.currentUser!.id) as List;
      final low = <({String id, String name, int credits})>[];
      if (mine.isNotEmpty) {
        final ids = [for (final m in mine) m['id'] as String];
        final bal = await db
            .from('member_package_balances')
            .select('member_id, credits_remaining')
            .eq('status', 'ACTIVE')
            .eq('kind', 'CREDITS')
            .inFilter('member_id', ids)
            .lte('credits_remaining', lowCreditLimit) as List;
        final lowNames = bal.isEmpty
            ? <String, String>{}
            : await nameMap([for (final b in bal) b['member_id'] as String]);
        for (final b in bal) {
          low.add((
            id: b['member_id'] as String,
            name: lowNames[b['member_id']] ?? 'Member',
            credits: b['credits_remaining'] as int,
          ));
        }
        low.sort((a, b) => a.credits != b.credits
            ? a.credits.compareTo(b.credits)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }

      final rows = <_Row>[
        for (final s in slots)
          for (final b in (s['bookings'] as List))
            if (b['status'] != 'CANCELLED')
              _Row(
                DateTime.parse(s['starts_at'] as String).toLocal(),
                DateTime.parse(s['ends_at'] as String).toLocal(),
                names[b['member_id']] ?? 'Unknown',
                b['id'] as String,
                b['status'] as String,
              ),
      ];
      if (!mounted || day != _day) return;
      setState(() {
        _rows = rows;
        _low = low;
        _error = null;
      });
    } catch (_) {
      if (!mounted || _rows != null) return;
      setState(() => _error = 'Could not load. Pull down to retry.');
    }
  }

  Future<void> _noShow(_Row r) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Mark as no-show?'),
        content: Text(
            '${r.memberName} will lose 1 credit for the ${showTime(r.startsAt)} session.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text('No-show')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('mark_no_show', params: {'p_booking': r.bookingId});
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    int count(String s) => rows?.where((r) => r.status == s).length ?? 0;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isToday ? 'Today' : 'Sessions'),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () =>
                    _goTo(DateTime(_day.year, _day.month, _day.day - 1)),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _day,
                      firstDate: DateTime(2024),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) _goTo(d);
                  },
                  child: Text('${weekdays[_day.weekday - 1]} ${showDate(_day)}',
                      style: theme.textTheme.titleMedium),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () =>
                    _goTo(DateTime(_day.year, _day.month, _day.day + 1)),
              ),
              TextButton(
                  onPressed: _isToday ? null : () => _goTo(DateTime.now()),
                  child: const Text('Today')),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: rows == null
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      Center(
                          child: _error == null
                              ? const CircularProgressIndicator()
                              : Text(_error!)),
                    ])
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Row(children: [
                          _stat(theme, 'Booked', count('BOOKED')),
                          _stat(theme, 'Attended', count('ATTENDED')),
                          _stat(theme, 'No-shows', count('NO_SHOW')),
                        ]),
                        if (_low.isNotEmpty) _lowCredits(theme),
                        if (rows.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(
                                  child: Text('No sessions booked on this day.'))),
                        for (final r in rows) _card(theme, r, now),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lowCredits(ThemeData theme) => Card(
        margin: const EdgeInsets.only(top: 16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(children: [
                  Icon(Icons.warning_amber, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Text('Running low on credits',
                      style: theme.textTheme.titleMedium),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                    'Members with $lowCreditLimit credits left or fewer.',
                    style: theme.textTheme.bodySmall),
              ),
              for (final m in _low)
                ListTile(
                  dense: true,
                  title: Text(m.name),
                  trailing: Text(
                      '${m.credits} left',
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: m.credits <= 1
                              ? theme.colorScheme.error
                              : null)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          CoachMemberDetail(id: m.id, name: m.name))),
                ),
            ],
          ),
        ),
      );

  Widget _stat(ThemeData theme, String label, int n) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              Text('$n', style: theme.textTheme.headlineSmall),
              Text(label),
            ]),
          ),
        ),
      );

  Widget _card(ThemeData theme, _Row r, DateTime now) {
    final (label, color) = switch (r.status) {
      'ATTENDED' => ('Attended', theme.colorScheme.primary),
      'NO_SHOW' => ('No-show', theme.colorScheme.error),
      _ => ('Booked', theme.colorScheme.onSurfaceVariant),
    };
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(children: [
              Text(showTime(r.startsAt), style: theme.textTheme.titleLarge),
              const SizedBox(width: 12),
              Expanded(
                  child:
                      Text(r.memberName, style: theme.textTheme.titleMedium)),
              Text(label,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            ]),
            if (r.status == 'BOOKED' && !now.isBefore(r.startsAt))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => _noShow(r),
                    child: const Text('Mark no-show')),
              ),
          ],
        ),
      ),
    );
  }
}
