import 'dart:math';

import 'package:flutter/material.dart';

import '../shared/common.dart';

// ---------------------------------------------------------------- helpers

/// Reads every row of a query, 1000 at a time (the server's page limit).
Future<List<Map<String, dynamic>>> _fetchAll(
    Future<List<Map<String, dynamic>>> Function(int from, int to) page) async {
  final out = <Map<String, dynamic>>[];
  for (var from = 0;; from += 1000) {
    final rows = await page(from, from + 999);
    out.addAll(rows);
    if (rows.length < 1000) break;
  }
  return out;
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

String _startUtc(DateTimeRange r) => r.start.toUtc().toIso8601String();
String _endUtc(DateTimeRange r) =>
    DateTime(r.end.year, r.end.month, r.end.day + 1).toUtc().toIso8601String();

Widget _empty(String text) =>
    Padding(padding: const EdgeInsets.all(40), child: Center(child: Text(text)));

Widget _statCard(BuildContext context, String label, Object value) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(children: [
            Text('$value', style: Theme.of(context).textTheme.headlineSmall),
            Text(label, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );

/// Page with a date-range bar; [builder] makes the report for the chosen range.
class _RangeReport extends StatefulWidget {
  const _RangeReport({required this.title, required this.builder});
  final String title;
  final Widget Function(DateTimeRange range) builder;

  @override
  State<_RangeReport> createState() => _RangeReportState();
}

class _RangeReportState extends State<_RangeReport> {
  late DateTimeRange _range = DateTimeRange(
      start: _today().subtract(const Duration(days: 29)), end: _today());

  Future<void> _pick() async {
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (r != null) setState(() => _range = r);
  }

  void _preset(int days) => setState(() => _range = DateTimeRange(
      start: _today().subtract(Duration(days: days - 1)), end: _today()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        ListTile(
          leading: const Icon(Icons.date_range),
          title: Text('${showDate(_range.start)}  to  ${showDate(_range.end)}'),
          trailing: const Icon(Icons.edit_calendar_outlined),
          onTap: _pick,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 8, children: [
            ActionChip(label: const Text('Last 7 days'), onPressed: () => _preset(7)),
            ActionChip(label: const Text('Last 30 days'), onPressed: () => _preset(30)),
            ActionChip(label: const Text('Last 90 days'), onPressed: () => _preset(90)),
          ]),
        ),
        const SizedBox(height: 4),
        Expanded(child: widget.builder(_range)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ menu

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String title, String sub, Widget page) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(children: [
        item(Icons.fact_check_outlined, 'Attendance',
            'Who attended or no-showed, with times', const AttendanceReport()),
        item(Icons.bar_chart, 'Member traffic',
            'Gym visits per day, member and coach', const TrafficReport()),
        item(Icons.toll_outlined, 'Credit usage',
            'Credits used, adjusted and left per member', const CreditUsageReport()),
        item(Icons.card_membership, 'Packages',
            'Active, expiring and expired packages', const PackageReport()),
      ]),
    );
  }
}

// ------------------------------------------------------------ attendance

class AttendanceReport extends StatefulWidget {
  const AttendanceReport({super.key});

  @override
  State<AttendanceReport> createState() => _AttendanceReportState();
}

class _AttendanceReportState extends State<AttendanceReport> {
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    return _RangeReport(
      title: 'Attendance report',
      builder: (range) => Loader<List<Map<String, dynamic>>>(
        key: ValueKey(range),
        load: () async {
          final from = isoDate(range.start), to = isoDate(range.end);
          final bk = await _fetchAll((f, t) => db
              .from('bookings')
              .select('id, status, booking_date, member_id, slots(starts_at, coach_id)')
              .inFilter('status', ['ATTENDED', 'NO_SHOW'])
              .gte('booking_date', from)
              .lte('booking_date', to)
              .order('booking_date', ascending: false)
              .order('id')
              .range(f, t));
          final att = await _fetchAll((f, t) => db
              .from('attendance')
              .select('booking_id, checked_in_at, method')
              .gte('attendance_date', from)
              .lte('attendance_date', to)
              .order('id')
              .range(f, t));
          final checkIn = {
            for (final a in att)
              a['booking_id'] as String: (
                at: DateTime.parse(a['checked_in_at'] as String).toLocal(),
                method: a['method'] as String,
              )
          };
          final ids = <String>{};
          for (final b in bk) {
            ids.add(b['member_id'] as String);
            final s = b['slots'] as Map?;
            if (s != null) ids.add(s['coach_id'] as String);
          }
          final names = await nameMap(ids);
          final rows = [
            for (final b in bk)
              {
                'date': b['booking_date'] as String,
                'status': b['status'] as String,
                'member': names[b['member_id']] ?? 'Unknown',
                'coach': names[(b['slots'] as Map?)?['coach_id']] ?? '',
                'starts': (b['slots'] as Map?) == null
                    ? null
                    : DateTime.parse((b['slots'] as Map)['starts_at'] as String)
                        .toLocal(),
                'checkIn': checkIn[b['id']],
              }
          ]..sort((a, b) {
              final c = (b['date'] as String).compareTo(a['date'] as String);
              if (c != 0) return c;
              final x = a['starts'] as DateTime?, y = b['starts'] as DateTime?;
              return x == null || y == null ? 0 : y.compareTo(x);
            });
          return rows;
        },
        builder: (context, rows, reload) {
          final attended = rows.where((r) => r['status'] == 'ATTENDED').length;
          final noShow = rows.length - attended;
          final shown = rows
              .where((r) =>
                  _filter == 'All' ||
                  (_filter == 'Attended') == (r['status'] == 'ATTENDED'))
              .toList();
          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              _statCard(context, 'Attended', attended),
              _statCard(context, 'No-shows', noShow),
            ]),
            Wrap(spacing: 8, children: [
              for (final f in const ['All', 'Attended', 'No-show'])
                ChoiceChip(
                  label: Text(f),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ]),
            if (shown.isEmpty) _empty('Nothing in this period.'),
            for (final r in shown) _row(context, r),
          ]);
        },
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> r) {
    final starts = r['starts'] as DateTime?;
    final ci = r['checkIn'] as ({DateTime at, String method})?;
    final attended = r['status'] == 'ATTENDED';
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(r['member'] as String),
      subtitle: Text([
        showIso(r['date'] as String),
        if (starts != null) 'Booked ${showTime(starts)}',
        if (ci != null)
          'In ${showTime(ci.at)}${ci.method == 'MANUAL' ? ' (manual)' : ''}',
        if ((r['coach'] as String).isNotEmpty) 'Coach ${r['coach']}',
      ].join('  ·  ')),
      trailing: Text(
        attended ? 'Attended' : 'No-show',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: attended ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- traffic

class TrafficReport extends StatefulWidget {
  const TrafficReport({super.key});

  @override
  State<TrafficReport> createState() => _TrafficReportState();
}

class _TrafficReportState extends State<TrafficReport> {
  int _view = 0;

  @override
  Widget build(BuildContext context) {
    return _RangeReport(
      title: 'Member traffic',
      builder: (range) => Loader<
          ({int total, List<(String, int)> days, List<(String, int)> members, List<(String, int)> coaches})>(
        key: ValueKey(range),
        load: () async {
          final att = await _fetchAll((f, t) => db
              .from('attendance')
              .select('attendance_date, member_id, coach_id')
              .gte('attendance_date', isoDate(range.start))
              .lte('attendance_date', isoDate(range.end))
              .order('id')
              .range(f, t));
          final names = await nameMap([
            for (final a in att) ...[a['member_id'] as String, a['coach_id'] as String]
          ]);
          Map<String, int> count(String key) {
            final m = <String, int>{};
            for (final a in att) {
              final k = a[key] as String;
              m[k] = (m[k] ?? 0) + 1;
            }
            return m;
          }

          List<(String, int)> byCount(Map<String, int> m) => [
                for (final e in m.entries) (names[e.key] ?? 'Unknown', e.value)
              ]..sort((a, b) => b.$2.compareTo(a.$2));

          final days = [
            for (final e in count('attendance_date').entries) (e.key, e.value)
          ]..sort((a, b) => b.$1.compareTo(a.$1));
          return (
            total: att.length,
            days: [for (final d in days) (showIso(d.$1), d.$2)],
            members: byCount(count('member_id')),
            coaches: byCount(count('coach_id')),
          );
        },
        builder: (context, d, reload) {
          final list = switch (_view) {
            0 => d.days,
            1 => d.members,
            _ => d.coaches,
          };
          final maxV = list.isEmpty ? 1 : list.map((e) => e.$2).reduce(max);
          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              _statCard(context, 'Total visits', d.total),
              _statCard(context, 'Members seen', d.members.length),
            ]),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Per day')),
                ButtonSegment(value: 1, label: Text('Per member')),
                ButtonSegment(value: 2, label: Text('Per coach')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            if (list.isEmpty) _empty('No visits in this period.'),
            for (final e in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.$1),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(value: e.$2 / maxV),
                ),
                trailing: Text('${e.$2}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------- credit usage

class _CreditRow {
  _CreditRow(this.name);
  final String name;
  int starting = 0;
  int attendance = 0;
  int noShow = 0;
  int adjustments = 0;
  int? balance;
}

class CreditUsageReport extends StatelessWidget {
  const CreditUsageReport({super.key});

  @override
  Widget build(BuildContext context) {
    return _RangeReport(
      title: 'Credit usage',
      builder: (range) => Loader<List<_CreditRow>>(
        key: ValueKey(range),
        load: () async {
          final tx = await _fetchAll((f, t) => db
              .from('credit_transactions')
              .select('member_id, type, delta, is_void')
              .gte('created_at', _startUtc(range))
              .lt('created_at', _endUtc(range))
              .order('id')
              .range(f, t));
          final bal = await _fetchAll((f, t) => db
              .from('member_package_balances')
              .select('member_id, credits_remaining')
              .eq('status', 'ACTIVE')
              .eq('kind', 'CREDITS')
              .order('member_package_id')
              .range(f, t));
          final ids = <String>{
            for (final r in tx) r['member_id'] as String,
            for (final r in bal) r['member_id'] as String,
          };
          final names = await nameMap(ids);
          final byMember = <String, _CreditRow>{};
          _CreditRow row(String id) =>
              byMember.putIfAbsent(id, () => _CreditRow(names[id] ?? 'Unknown'));
          for (final r in tx) {
            final x = row(r['member_id'] as String);
            final delta = r['delta'] as int;
            final voided = r['is_void'] as bool;
            switch (r['type'] as String) {
              case 'PACKAGE_START':
                x.starting += delta;
              case 'CHECK_IN':
                if (!voided) x.attendance += -delta;
              case 'NO_SHOW':
                if (!voided) x.noShow += -delta;
              case 'ADMIN_ADJUSTMENT' || 'REVERSAL':
                x.adjustments += delta;
            }
          }
          for (final r in bal) {
            row(r['member_id'] as String).balance = r['credits_remaining'] as int;
          }
          return byMember.values.toList()
            ..sort((a, b) => a.name.compareTo(b.name));
        },
        builder: (context, rows, reload) {
          int sum(int Function(_CreditRow) f) => rows.fold(0, (a, r) => a + f(r));
          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              _statCard(context, 'Credits sold', sum((r) => r.starting)),
              _statCard(context, 'Used', sum((r) => r.attendance)),
              _statCard(context, 'No-shows', sum((r) => r.noShow)),
            ]),
            if (rows.isEmpty) _empty('No credit activity in this period.'),
            for (final r in rows)
              Card(
                margin: const EdgeInsets.only(top: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(r.name,
                                style: Theme.of(context).textTheme.titleMedium)),
                        Text('Balance: ${r.balance ?? '-'}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ]),
                      const SizedBox(height: 4),
                      Text('Starting ${r.starting}   ·   Attendance -${r.attendance}'
                          '   ·   No-show -${r.noShow}   ·   Adjustments '
                          '${r.adjustments > 0 ? '+' : ''}${r.adjustments}'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Starting, attendance, no-show and adjustment figures cover the '
              'chosen dates. Balance is today\'s balance on the active package.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]);
        },
      ),
    );
  }
}

// -------------------------------------------------------------- packages

class PackageReport extends StatefulWidget {
  const PackageReport({super.key});

  @override
  State<PackageReport> createState() => _PackageReportState();
}

class _PackageReportState extends State<PackageReport> {
  String _filter = 'Active';
  static const _filters = ['Active', 'Nearing expiry', 'Expired', 'Used up'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Package report')),
      body: Loader<List<Map<String, dynamic>>>(
        load: () async {
          final pk = await _fetchAll((f, t) => db
              .from('member_packages')
              .select('id, member_id, package_name, status, expiry_date, starting_credits')
              .order('expiry_date')
              .order('id')
              .range(f, t));
          final bal = await _fetchAll((f, t) => db
              .from('member_package_balances')
              .select('member_package_id, credits_remaining')
              .order('member_package_id')
              .range(f, t));
          final left = {
            for (final b in bal)
              b['member_package_id'] as String: b['credits_remaining'] as int
          };
          final names = await nameMap([for (final p in pk) p['member_id'] as String]);
          return [
            for (final p in pk)
              {
                ...p,
                'member': names[p['member_id']] ?? 'Unknown',
                'left': left[p['id']] ?? 0,
              }
          ];
        },
        builder: (context, pk, reload) {
          final soon = _today().add(const Duration(days: 14));
          bool nearing(Map<String, dynamic> p) =>
              p['status'] == 'ACTIVE' &&
              !DateTime.parse(p['expiry_date'] as String).isAfter(soon);
          final groups = <String, List<Map<String, dynamic>>>{
            'Active': pk.where((p) => p['status'] == 'ACTIVE').toList(),
            'Nearing expiry': pk.where(nearing).toList(),
            'Expired': pk.where((p) => p['status'] == 'EXPIRED').toList(),
            'Used up': pk.where((p) => p['status'] == 'EXHAUSTED').toList(),
          };
          final remaining = groups['Active']!
              .fold<int>(0, (a, p) => a + (p['left'] as int));
          final shown = groups[_filter]!;
          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              _statCard(context, 'Active', groups['Active']!.length),
              _statCard(context, 'Nearing expiry', groups['Nearing expiry']!.length),
              _statCard(context, 'Expired', groups['Expired']!.length),
              _statCard(context, 'Credits left', remaining),
            ]),
            Wrap(spacing: 8, children: [
              for (final f in _filters)
                ChoiceChip(
                  label: Text('$f (${groups[f]!.length})'),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ]),
            if (shown.isEmpty) _empty('No packages here.'),
            for (final p in shown)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(p['member'] as String),
                subtitle: Text('${p['package_name']}  ·  expires '
                    '${showIso(p['expiry_date'] as String)}'),
                trailing: Text('${p['left']} / ${p['starting_credits']}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Nearing expiry = active and ends within 14 days.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ]);
        },
      ),
    );
  }
}
