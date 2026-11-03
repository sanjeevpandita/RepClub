import 'package:flutter/material.dart';

import '../shared/common.dart';
import '../shared/workout.dart';

/// Member: the workouts their coach has given them.
class MemberWorkoutsScreen extends StatelessWidget {
  const MemberWorkoutsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My workouts')),
      body: WorkoutPlanList(memberId: db.auth.currentUser!.id, canManage: false),
    );
  }
}

/// Today's workout, or the next one, for the Home screen. Null if none
/// (or if the workout tables are not set up yet).
Future<Map<String, dynamic>?> loadNextWorkout() async {
  try {
    final r = await db
        .from('workout_plans')
        .select('id, plan_date, muscle_groups(name), workout_plan_exercises(id)')
        .eq('member_id', db.auth.currentUser!.id)
        .gte('plan_date', todayIso())
        .order('plan_date', ascending: true)
        .limit(1) as List;
    return r.isEmpty ? null : r.first as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

class NextWorkoutCard extends StatelessWidget {
  const NextWorkoutCard({super.key, required this.plan, required this.reload});
  final Map<String, dynamic>? plan;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = plan;
    if (p == null) return const SizedBox.shrink();
    final isToday = p['plan_date'] == todayIso();
    final group = (p['muscle_groups'] as Map?)?['name'] ?? 'Workout';
    final count = (p['workout_plan_exercises'] as List).length;
    return Card(
      child: ListTile(
        leading: Icon(Icons.sports_gymnastics, color: theme.colorScheme.primary),
        title: Text(isToday ? "Today's workout: $group" : 'Next workout: $group'),
        subtitle: Text(
            '${isToday ? 'Today' : showDay(p['plan_date'])}  ·  $count exercises'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  WorkoutPlanScreen(planId: p['id'] as String, canManage: false)));
          await reload();
        },
      ),
    );
  }
}
