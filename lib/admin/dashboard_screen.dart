import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/common.dart';
import 'add_workout_screen.dart';
import 'today_screen.dart';

class _Entry {
  _Entry(this.name, this.detail);
  final String name;
  final String detail;
}

class _Occupancy {
  _Occupancy(this.time, this.taken, this.capacity);
  final DateTime time;
  final int taken;
  final int capacity;
}

class _DashData {
  _DashData({
    required this.activeMembers,
    required this.checkedIn,
    required this.upcoming,
    required this.noShows,
    required this.occupancy,
    required this.lowCredit,
    required this.lowCreditLevel,
    required this.expiring,
    required this.expiryDays,
  });
  final int activeMembers;
  final int checkedIn;
  final int upcoming;
  final int noShows;
  final List<_Occupancy> occupancy;
  final List<_Entry> lowCredit;
  final int lowCreditLevel;
  final List<_Entry> expiring;
  final int expiryDays;
}

Future<_DashData> _load() async {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final end = DateTime(now.year, now.month, now.day + 1);

  final members = await db
      .from('profiles')
      .select('id')
      .eq('role', 'MEMBER')
      .eq('is_active', true)
      .count(CountOption.exact);

  final slots = await db
      .from('slots')
      .select('starts_at, capacity, bookings(status)')
      .eq('is_cancelled', false)
      .gte('starts_at', start.toUtc().toIso8601String())
      .lt('starts_at', end.toUtc().toIso8601String())
      .order('starts_at');

  var checkedIn = 0, noShows = 0, upcoming = 0;
  final byTime = <DateTime, ({int taken, int cap})>{};
  for (final s in slots) {
    final starts = DateTime.parse(s['starts_at'] as String).toLocal();
    var taken = 0;
    for (final b in (s['bookings'] as List)) {
      final status = b['status'] as String;
      if (status == 'ATTENDED') checkedIn++;
      if (status == 'NO_SHOW') noShows++;
      if (status == 'BOOKED' && starts.isAfter(now)) upcoming++;
      if (status == 'BOOKED' || status == 'ATTENDED' || status == 'NO_SHOW') {
        taken++;
      }
    }
    final prev = byTime[starts];
    byTime[starts] = (
      taken: (prev?.taken ?? 0) + taken,
      cap: (prev?.cap ?? 0) + (s['capacity'] as int),
    );
  }
  final occupancy = [
    for (final e in byTime.entries) _Occupancy(e.key, e.value.taken, e.value.cap)
  ]..sort((a, b) => a.time.compareTo(b.time));

  final ns = await db
      .from('notification_settings')
      .select('type, threshold')
      .inFilter('type', ['LOW_CREDIT', 'PACKAGE_EXPIRY']);
  int level(String type, int fallback) {
    for (final r in ns) {
      if (r['type'] == type && r['threshold'] != null) {
        return r['threshold'] as int;
      }
    }
    return fallback;
  }

  final lowLevel = level('LOW_CREDIT', 2);
  final expiryDays = level('PACKAGE_EXPIRY', 7);

  final bal = await db
      .from('member_package_balances')
      .select('member_id, credits_remaining, expiry_date')
      .eq('status', 'ACTIVE')
      .eq('kind', 'CREDITS');
  final names = await nameMap([for (final b in bal) b['member_id'] as String]);

  final today = DateTime(now.year, now.month, now.day);
  final soon = today.add(Duration(days: expiryDays));
  final low = <_Entry>[];
  final exp = <_Entry>[];
  for (final b in bal) {
    final name = names[b['member_id']] ?? 'Unknown';
    final left = b['credits_remaining'] as int;
    final expiry = DateTime.parse(b['expiry_date'] as String);
    if (left <= lowLevel) {
      low.add(_Entry(name, '$left credit${left == 1 ? '' : 's'} left'));
    }
    if (!expiry.isBefore(today) && !expiry.isAfter(soon)) {
      exp.add(_Entry(name, 'Expires ${showDate(expiry)}'));
    }
  }
  low.sort((a, b) => a.name.compareTo(b.name));
  exp.sort((a, b) => a.name.compareTo(b.name));

  return _DashData(
    activeMembers: members.count,
    checkedIn: checkedIn,
    upcoming: upcoming,
    noShows: noShows,
    occupancy: occupancy,
    lowCredit: low,
    lowCreditLevel: lowLevel,
    expiring: exp,
    expiryDays: expiryDays,
  );
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: Loader<_DashData>(
        load: _load,
        builder: (context, d, reload) {
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(children: [
                _stat(context, 'Active members', d.activeMembers),
                _stat(context, 'Checked in today', d.checkedIn),
                _stat(context, 'Upcoming today', d.upcoming),
              ]),
              Row(children: [
                _stat(context, 'No-shows today', d.noShows),
                _stat(context, 'Low credit', d.lowCredit.length),
                _stat(context, 'Expiring soon', d.expiring.length),
              ]),
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.today),
                label: const Text("Open today's attendance"),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TodayScreen())),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                _action(context, Icons.event_available, 'Create booking',
                    '/admin/calendar'),
                _action(context, Icons.card_membership, 'Assign package',
                    '/admin/members'),
                _action(context, Icons.person_add_alt, 'Add member',
                    '/admin/members'),
                _action(context, Icons.sports, 'Add coach', '/admin/coaches'),
                _action(context, Icons.fitness_center, 'Add equipment',
                    '/admin/more/equipment'),
                ActionChip(
                  avatar: const Icon(Icons.sports_gymnastics, size: 18),
                  label: const Text('Add workout'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PickMemberForWorkoutScreen())),
                ),
              ]),
              _section(theme, "Today's occupancy"),
              if (d.occupancy.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No sessions today.')),
              for (final o in d.occupancy)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(showTime(o.time), style: theme.textTheme.titleMedium),
                  title: LinearProgressIndicator(
                      value: o.capacity == 0
                          ? 0
                          : (o.taken / o.capacity).clamp(0, 1).toDouble()),
                  trailing: Text('${o.taken}/${o.capacity}'),
                ),
              _section(theme, 'Low credit  (${d.lowCreditLevel} or fewer)'),
              if (d.lowCredit.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('Nobody.')),
              for (final e in d.lowCredit) _entry(e),
              _section(theme, 'Packages expiring in ${d.expiryDays} days'),
              if (d.expiring.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('None.')),
              for (final e in d.expiring) _entry(e),
            ],
          );
        },
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int value) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: Column(children: [
              Text('$value', style: Theme.of(context).textTheme.headlineMedium),
              Text(label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );

  Widget _action(
          BuildContext context, IconData icon, String label, String path) =>
      ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onPressed: () => context.go(path),
      );

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(title, style: theme.textTheme.titleMedium),
      );

  Widget _entry(_Entry e) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.person_outline),
        title: Text(e.name),
        trailing: Text(e.detail),
      );
}
