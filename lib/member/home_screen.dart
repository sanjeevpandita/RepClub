import 'package:flutter/material.dart';

import '../shared/avatar.dart';
import '../shared/common.dart';
import 'checkin_screen.dart';
import 'weight_chart.dart';
import 'workouts_screen.dart';

class _Home {
  _Home({
    required this.pkg,
    required this.pass,
    required this.credits,
    required this.coachName,
    required this.coachAvatar,
    required this.upcoming,
    required this.attended,
    required this.weights,
    required this.lowLevel,
    required this.workout,
  });
  final Map<String, dynamic>? pkg; // active credit package + balance
  final Map<String, dynamic>? pass; // active Monthly Pass
  final int credits;
  final String? coachName;
  final String? coachAvatar;
  final List<Map<String, dynamic>> upcoming;
  final List<Map<String, dynamic>> attended;
  final List<Map<String, dynamic>> weights; // oldest first
  final int lowLevel;
  final Map<String, dynamic>? workout; // today's or next workout
}

Future<_Home> _load() async {
  final uid = db.auth.currentUser!.id;
  final nowIso = DateTime.now().toUtc().toIso8601String();

  final results = await Future.wait<dynamic>([
    db
        .from('member_package_balances')
        .select('member_package_id, expiry_date, credits_remaining')
        .eq('member_id', uid)
        .eq('status', 'ACTIVE')
        .eq('kind', 'CREDITS')
        .maybeSingle(),
    db
        .from('member_profiles')
        .select('primary_coach_id')
        .eq('id', uid)
        .maybeSingle(),
    db
        .from('bookings')
        .select('id, slots!inner(starts_at, ends_at)')
        .eq('member_id', uid)
        .eq('status', 'BOOKED')
        .gte('slots.ends_at', nowIso)
        .limit(20),
    db
        .from('attendance')
        .select('attendance_date, checked_in_at')
        .eq('member_id', uid)
        .order('checked_in_at', ascending: false)
        .limit(5),
    db
        .from('weight_logs')
        .select('weight_kg, logged_on')
        .eq('member_id', uid)
        .order('logged_on', ascending: false)
        .order('created_at', ascending: false)
        .limit(60),
    db
        .from('notification_settings')
        .select('threshold')
        .eq('type', 'LOW_CREDIT')
        .maybeSingle(),
    db
        .from('member_packages')
        .select('package_name, expiry_date')
        .eq('member_id', uid)
        .eq('kind', 'PASS')
        .eq('status', 'ACTIVE')
        .maybeSingle(),
    db
        .from('gym_bookings')
        .select('hour_start')
        .eq('member_id', uid)
        .eq('status', 'BOOKED')
        .gte('hour_start',
            DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String())
        .limit(20),
    db
        .from('gym_bookings')
        .select('booking_date, checked_in_at')
        .eq('member_id', uid)
        .eq('status', 'ATTENDED')
        .order('checked_in_at', ascending: false)
        .limit(5),
  ]);

  final bal = results[0] as Map<String, dynamic>?;
  String? pkgName;
  if (bal != null) {
    final p = await db
        .from('member_packages')
        .select('package_name')
        .eq('id', bal['member_package_id'])
        .maybeSingle();
    pkgName = p?['package_name'] as String?;
  }

  final coachId =
      (results[1] as Map<String, dynamic>?)?['primary_coach_id'] as String?;
  Map<String, dynamic>? coach;
  if (coachId != null) {
    coach = await db
        .from('profiles')
        .select('full_name, avatar_url')
        .eq('id', coachId)
        .maybeSingle();
  }

  // Gym hours are shown like sessions: same shape as a coached booking.
  final gymUpcoming = [
    for (final g in (results[7] as List))
      {
        'slots': {
          'starts_at': g['hour_start'] as String,
          'ends_at': DateTime.parse(g['hour_start'] as String)
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        }
      }
  ];
  final upcoming = [
    ...(results[2] as List).cast<Map<String, dynamic>>(),
    ...gymUpcoming,
  ]..sort((a, b) => (a['slots']['starts_at'] as String)
      .compareTo(b['slots']['starts_at'] as String));
  final attended = [
    ...(results[3] as List).cast<Map<String, dynamic>>(),
    ...(results[8] as List).cast<Map<String, dynamic>>(),
  ]..sort((a, b) =>
      (b['checked_in_at'] as String).compareTo(a['checked_in_at'] as String));
  final weights = results[4] as List;
  final workout = await loadNextWorkout();

  return _Home(
    pkg: bal == null ? null : {...bal, 'package_name': pkgName},
    credits: (bal?['credits_remaining'] as int?) ?? 0,
    coachName: coach?['full_name'] as String?,
    coachAvatar: coach?['avatar_url'] as String?,
    upcoming: upcoming,
    pass: results[6] as Map<String, dynamic>?,
    attended: attended.take(5).toList(),
    weights: weights.reversed.cast<Map<String, dynamic>>().toList(),
    lowLevel:
        ((results[5] as Map<String, dynamic>?)?['threshold'] as int?) ?? 2,
    workout: workout,
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _when(String startsAt, String endsAt) {
  final s = DateTime.parse(startsAt).toLocal();
  final e = DateTime.parse(endsAt).toLocal();
  return '${_weekdays[s.weekday - 1]} ${showDate(s)}, ${showTime(s)}-${showTime(e)}';
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Hi ${name.split(' ').first}')),
      body: Loader<_Home>(
        load: _load,
        builder: (context, h, reload) {
          final low = h.pkg != null && h.credits <= h.lowLevel;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (h.pass != null)
                Card(
                  child: ListTile(
                    leading:
                        Icon(Icons.fitness_center, color: theme.colorScheme.primary),
                    title: Text(h.pass!['package_name'] as String? ?? 'Monthly Pass'),
                    subtitle: Text(
                        'Unlimited gym visits - expires ${showIso(h.pass!['expiry_date'])}'),
                  ),
                ),
              if (h.pkg == null && h.pass == null)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('No active package'),
                    subtitle: Text('Please contact the gym to get started.'),
                  ),
                )
              else if (h.pkg != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Credits left',
                                      style: theme.textTheme.labelLarge),
                                  Text('${h.credits}',
                                      style: theme.textTheme.displayMedium
                                          ?.copyWith(
                                              color: theme.colorScheme.primary,
                                              fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(h.pkg!['package_name'] ?? 'Package',
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold)),
                                    Text(
                                        'Expires ${showIso(h.pkg!['expiry_date'])}',
                                        style: theme.textTheme.bodyMedium),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (low) ...[
                          const SizedBox(height: 12),
                          Row(children: [
                            Icon(Icons.warning_amber,
                                color: theme.colorScheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    'Running low on credits. Ask the gym for a top-up.',
                                    style: TextStyle(
                                        color: theme.colorScheme.error))),
                          ]),
                        ],
                      ],
                    ),
                  ),
                ),
              if (h.coachName != null)
                Card(
                  child: ListTile(
                    leading: Avatar(name: h.coachName!, url: h.coachAvatar),
                    title: Text(h.coachName!),
                    subtitle: const Text('Your coach'),
                  ),
                ),
              NextWorkoutCard(plan: h.workout, reload: reload),
              if (h.coachName != null || h.pass != null)
                // Gym hours can be booked with a Monthly Pass or a coach (db/19).
                CheckInCard(hasCoach: h.coachName != null, reload: reload),
              _heading(context, 'Next session'),
              if (h.upcoming.isEmpty)
                const Card(child: ListTile(title: Text('Nothing booked yet')))
              else ...[
                Card(
                  child: ListTile(
                    leading: Icon(Icons.event_available,
                        color: theme.colorScheme.primary),
                    title: Text(_when(h.upcoming.first['slots']['starts_at'],
                        h.upcoming.first['slots']['ends_at'])),
                  ),
                ),
                if (h.upcoming.length > 1) ...[
                  _heading(context, 'Also booked'),
                  for (final b in h.upcoming.skip(1))
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.event),
                        title: Text(_when(
                            b['slots']['starts_at'], b['slots']['ends_at'])),
                      ),
                    ),
                ],
              ],
              _heading(context, 'Recent attendance'),
              if (h.attended.isEmpty)
                const Card(child: ListTile(title: Text('No sessions yet')))
              else
                Card(
                  child: Column(children: [
                    for (final a in h.attended)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.check_circle_outline),
                        title: Text(showStamp(a['checked_in_at'])),
                      ),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Weight', style: theme.textTheme.titleMedium),
                    TextButton.icon(
                      onPressed: () => logWeight(context, reload),
                      icon: const Icon(Icons.add),
                      label: const Text('Log weight'),
                    ),
                  ],
                ),
              ),
              Card(
                child: h.weights.isEmpty
                    ? const ListTile(
                        leading: Icon(Icons.monitor_weight_outlined),
                        title: Text('No weight logged yet'))
                    : WeightChart(logs: h.weights),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

/// Asks for a weight and date (default today) and saves it as the member's own check-in.
Future<void> logWeight(BuildContext context, Future<void> Function() reload) async {
  final ctl = TextEditingController();
  var date = DateTime.now();
  String? error;
  final result = await showDialog<({double kg, DateTime date})>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Log your weight'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: 'Weight (kg)',
                  errorText: error,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text('Date: ${showDate(date)}'),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: date,
                  firstDate: DateTime(now.year - 5),
                  lastDate: now,
                );
                if (picked != null) setState(() => date = picked);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctl.text.trim().replaceAll(',', '.'));
              if (v == null || v < 20 || v > 500) {
                setState(() => error = 'Enter a weight such as 72.5');
                return;
              }
              Navigator.pop(ctx, (kg: v, date: date));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (result == null || !context.mounted) return;
  final ok = await attempt(context, () async {
    await db.from('weight_logs').insert({
      'member_id': db.auth.currentUser!.id,
      'weight_kg': result.kg,
      'logged_on': isoDate(result.date),
    });
  });
  if (ok) await reload();
}
