import 'package:flutter/material.dart';

import '../shared/avatar.dart';
import '../shared/common.dart';
import '../shared/workout.dart';

/// Admin (from the Dashboard): pick a member, then see and assign their workouts.
class PickMemberForWorkoutScreen extends StatefulWidget {
  const PickMemberForWorkoutScreen({super.key});

  @override
  State<PickMemberForWorkoutScreen> createState() =>
      _PickMemberForWorkoutScreenState();
}

class _PickMemberForWorkoutScreenState extends State<PickMemberForWorkoutScreen> {
  String _query = '';

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await db
        .from('profiles')
        .select('id, full_name, avatar_url')
        .eq('role', 'MEMBER')
        .eq('is_active', true)
        .order('full_name', ascending: true) as List;
    return rows.cast<Map<String, dynamic>>();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add workout: choose member')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: 'Search by name',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: Loader<List<Map<String, dynamic>>>(
            load: _load,
            builder: (context, rows, reload) {
              final shown = rows
                  .where((r) => ((r['full_name'] as String?) ?? '')
                      .toLowerCase()
                      .contains(_query.toLowerCase()))
                  .toList();
              return ListView(children: [
                if (shown.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('No members found.'))),
                for (final r in shown)
                  ListTile(
                    leading: Avatar(
                        name: r['full_name'] as String? ?? '',
                        url: r['avatar_url'] as String?),
                    title: Text(r['full_name'] as String? ?? ''),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                            builder: (_) => MemberWorkoutsAdminScreen(
                                memberId: r['id'] as String,
                                name: r['full_name'] as String? ?? ''))),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// One member's workouts, with "Assign workout".
class MemberWorkoutsAdminScreen extends StatelessWidget {
  const MemberWorkoutsAdminScreen(
      {super.key, required this.memberId, required this.name});
  final String memberId;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Workouts: $name')),
      body: WorkoutPlanList(memberId: memberId, canManage: true),
    );
  }
}
