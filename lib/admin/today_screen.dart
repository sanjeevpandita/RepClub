import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/common.dart';

class _TodayRow {
  _TodayRow({
    required this.startsAt,
    required this.coachName,
    required this.memberName,
    required this.bookingId,
    required this.status,
    this.method,
  });
  final DateTime startsAt;
  final String coachName;
  final String memberName;
  final String bookingId;
  final String status;
  final String? method;
}

/// Live view of today's bookings: who is booked, who has checked in, no-shows.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  List<_TodayRow>? _rows;
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

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (d != null) _goTo(d);
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
          .select('id, coach_id, starts_at, bookings(id, status, member_id)')
          .eq('is_cancelled', false)
          .gte('starts_at', start.toUtc().toIso8601String())
          .lt('starts_at', end.toUtc().toIso8601String())
          .order('starts_at');

      final memberIds = <String>{};
      final coachIds = <String>{};
      final bookingIds = <String>[];
      for (final s in slots) {
        for (final b in (s['bookings'] as List)) {
          if (b['status'] == 'CANCELLED') continue;
          memberIds.add(b['member_id'] as String);
          coachIds.add(s['coach_id'] as String);
          bookingIds.add(b['id'] as String);
        }
      }
      final names = <String, String>{};
      final methods = <String, String>{};
      if (bookingIds.isNotEmpty) {
        final pr = await db.from('profiles').select('id, full_name').inFilter(
          'id',
          [...memberIds, ...coachIds],
        );
        for (final p in pr) {
          names[p['id'] as String] = p['full_name'] as String? ?? '';
        }
        final att = await db
            .from('attendance')
            .select('booking_id, method')
            .inFilter('booking_id', bookingIds);
        for (final a in att) {
          methods[a['booking_id'] as String] = a['method'] as String;
        }
      }

      final rows = <_TodayRow>[
        for (final s in slots)
          for (final b in (s['bookings'] as List))
            if (b['status'] != 'CANCELLED')
              _TodayRow(
                startsAt: DateTime.parse(s['starts_at'] as String).toLocal(),
                coachName: names[s['coach_id']] ?? '',
                memberName: names[b['member_id']] ?? 'Unknown',
                bookingId: b['id'] as String,
                status: b['status'] as String,
                method: methods[b['id']],
              ),
      ];
      // Ignore the result if the admin moved to another day meanwhile.
      if (!mounted || day != _day) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (_) {
      if (!mounted || _rows != null) return;
      setState(() => _error = 'Could not load today. Pull down to retry.');
    }
  }

  Future<void> _manualAttendance(_TodayRow r) async {
    final res = await showDialog<ReasonResult>(
      context: context,
      builder: (_) => const ReasonDialog(
        title: 'Mark attended (manual)',
        confirm: 'Mark attended',
      ),
    );
    if (res == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc(
        'admin_manual_attendance',
        params: {
          'p_booking': r.bookingId,
          'p_reason': res.reason,
          'p_note': res.note.isEmpty ? null : res.note,
        },
      );
    });
    if (ok) _load();
  }

  Future<void> _noShow(_TodayRow r) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Mark as no-show?'),
        content: Text(
          '${r.memberName} will lose 1 credit for the ${showTime(r.startsAt)} session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('No-show'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('mark_no_show', params: {'p_booking': r.bookingId});
    });
    if (ok) _load();
  }

  Future<void> _waive(_TodayRow r) async {
    final res = await showDialog<ReasonResult>(
      context: context,
      builder: (_) => const ReasonDialog(
        title: 'Waive no-show',
        confirm: 'Give credit back',
      ),
    );
    if (res == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc(
        'admin_waive_no_show',
        params: {
          'p_booking': r.bookingId,
          'p_reason': res.reason,
          'p_note': res.note.isEmpty ? null : res.note,
        },
      );
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final theme = Theme.of(context);
    int count(String s) => rows?.where((r) => r.status == s).length ?? 0;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Scaffold(
      appBar: AppBar(
        title: Text(_isToday ? 'Today' : 'Attendance'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
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
                  onPressed: _pickDay,
                  child: Text(
                    '${weekdays[_day.weekday - 1]} ${showDate(_day)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () =>
                    _goTo(DateTime(_day.year, _day.month, _day.day + 1)),
              ),
              TextButton(
                onPressed: _isToday ? null : () => _goTo(DateTime.now()),
                child: const Text('Today'),
              ),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: rows == null
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: _error == null
                              ? const CircularProgressIndicator()
                              : Text(_error!),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        Row(
                          children: [
                            _stat(context, 'Booked', count('BOOKED')),
                            _stat(context, 'Attended', count('ATTENDED')),
                            _stat(context, 'No-shows', count('NO_SHOW')),
                          ],
                        ),
                        if (rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Text('No bookings on this day.'),
                            ),
                          ),
                        for (final r in rows) _rowCard(theme, r),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int n) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Text('$n', style: Theme.of(context).textTheme.headlineSmall),
            Text(label),
          ],
        ),
      ),
    ),
  );

  Widget _rowCard(ThemeData theme, _TodayRow r) {
    final (label, color) = switch (r.status) {
      'ATTENDED' => (
        r.method == 'MANUAL' ? 'Attended (manual)' : 'Attended',
        theme.colorScheme.primary,
      ),
      'NO_SHOW' => ('No-show', theme.colorScheme.error),
      _ => ('Booked', theme.colorScheme.onSurfaceVariant),
    };
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(showTime(r.startsAt), style: theme.textTheme.titleLarge),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.memberName, style: theme.textTheme.titleMedium),
                      Text(
                        'Coach ${r.coachName}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (r.status == 'BOOKED')
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _noShow(r),
                    child: const Text('No-show'),
                  ),
                  TextButton(
                    onPressed: () => _manualAttendance(r),
                    child: const Text('Mark attended'),
                  ),
                ],
              ),
            if (r.status == 'NO_SHOW')
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _waive(r),
                  child: const Text('Waive no-show'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
