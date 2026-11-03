import 'package:flutter/material.dart';

import '../admin/members_screen.dart' show MemberEquipmentTab, MemberPackageTab;
import '../member/weight_chart.dart';
import '../shared/avatar.dart';
import '../shared/common.dart';
import '../shared/evaluation.dart';
import '../shared/reset_password.dart';
import '../shared/workout.dart';
import 'evaluation_form.dart';

class _M {
  _M(this.id, this.name, this.avatarUrl, this.credits, this.expiry);
  final String id;
  final String name;
  final String? avatarUrl;
  final int? credits;
  final String? expiry;
}

/// The coach's own members.
class CoachMembersScreen extends StatelessWidget {
  const CoachMembersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My members')),
      body: Loader<List<_M>>(
        load: () async {
          final mp = await db
              .from('member_profiles')
              .select('id')
              .eq('primary_coach_id', db.auth.currentUser!.id) as List;
          final ids = [for (final m in mp) m['id'] as String];
          if (ids.isEmpty) return <_M>[];
          final pr = await db
              .from('profiles')
              .select('id, full_name, avatar_url')
              .inFilter('id', ids) as List;
          final bal = await db
              .from('member_package_balances')
              .select('member_id, credits_remaining, expiry_date')
              .eq('status', 'ACTIVE')
              .eq('kind', 'CREDITS')
              .inFilter('member_id', ids) as List;
          final byId = {for (final b in bal) b['member_id'] as String: b};
          final list = [
            for (final p in pr)
              _M(
                p['id'] as String,
                (p['full_name'] as String?) ?? '',
                p['avatar_url'] as String?,
                byId[p['id']]?['credits_remaining'] as int?,
                byId[p['id']]?['expiry_date'] as String?,
              )
          ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return list;
        },
        builder: (context, list, reload) {
          if (list.isEmpty) {
            return ListView(children: const [
              SizedBox(height: 80),
              Center(child: Text('You have no members yet.')),
            ]);
          }
          final theme = Theme.of(context);
          return ListView(
            children: [
              for (final m in list)
                ListTile(
                  leading: Avatar(name: m.name, url: m.avatarUrl),
                  title: Text(m.name),
                  subtitle: Text(m.credits == null
                      ? 'No active package'
                      : '${m.credits} credits left - expires ${showIso(m.expiry!)}'),
                  trailing: m.credits != null && m.credits! <= lowCreditLimit
                      ? Icon(Icons.warning_amber,
                          color: theme.colorScheme.error)
                      : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CoachMemberDetail(id: m.id, name: m.name))),
                ),
            ],
          );
        },
      ),
    );
  }
}

class CoachMemberDetail extends StatelessWidget {
  const CoachMemberDetail({super.key, required this.id, required this.name});
  final String id;
  final String name;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name),
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Overview'),
            Tab(text: 'Workouts'),
            Tab(text: 'Packages'),
            Tab(text: 'Evaluations'),
            Tab(text: 'Equipment'),
          ]),
        ),
        body: TabBarView(children: [
          _Overview(memberId: id, name: name),
          WorkoutPlanList(memberId: id, canManage: true),
          MemberPackageTab(memberId: id),
          _Evaluations(memberId: id),
          MemberEquipmentTab(memberId: id),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- overview

class _Overview extends StatelessWidget {
  const _Overview({required this.memberId, required this.name});
  final String memberId;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Loader<
        ({
          Map<String, dynamic>? pkg,
          List<Map<String, dynamic>> weights,
          List<Map<String, dynamic>> sessions
        })>(
      load: () async {
        final bal = await db
            .from('member_package_balances')
            .select('member_package_id, expiry_date, credits_remaining')
            .eq('member_id', memberId)
            .eq('status', 'ACTIVE')
            .eq('kind', 'CREDITS')
            .maybeSingle();
        Map<String, dynamic>? pkg = bal;
        if (bal != null) {
          final mp = await db
              .from('member_packages')
              .select('package_name')
              .eq('id', bal['member_package_id'])
              .maybeSingle();
          pkg = {...bal, 'package_name': mp?['package_name'] ?? 'Package'};
        }
        final w = await db
            .from('weight_logs')
            .select('weight_kg, logged_on')
            .eq('member_id', memberId)
            .order('logged_on', ascending: false)
            .limit(30) as List;
        final s = await db
            .from('attendance')
            .select('attendance_date, method')
            .eq('member_id', memberId)
            .order('attendance_date', ascending: false)
            .limit(10) as List;
        return (
          pkg: pkg,
          weights: w.cast<Map<String, dynamic>>().reversed.toList(),
          sessions: s.cast<Map<String, dynamic>>(),
        );
      },
      builder: (context, d, reload) {
        final theme = Theme.of(context);
        return ListView(
          children: [
            _SelfBookSwitch(memberId: memberId),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ResetPasswordButton(userId: memberId, name: name),
              ),
            ),
            Card(
              margin: const EdgeInsets.all(12),
              child: ListTile(
                title: Text(d.pkg == null
                    ? 'No active package'
                    : d.pkg!['package_name'] as String),
                subtitle: d.pkg == null
                    ? null
                    : Text('Expires ${showIso(d.pkg!['expiry_date'])}'),
                trailing: d.pkg == null
                    ? null
                    : Text('${d.pkg!['credits_remaining']}\ncredits',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Weight', style: theme.textTheme.titleMedium),
            ),
            if (d.weights.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No weight logged yet.'))
            else
              WeightChart(logs: d.weights),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Recent attendance', style: theme.textTheme.titleMedium),
            ),
            if (d.sessions.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No attendance yet.')),
            for (final a in d.sessions)
              ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(showIso(a['attendance_date'] as String)),
                subtitle: Text(a['method'] == 'MANUAL' ? 'Manual' : 'QR'),
              ),
          ],
        );
      },
    );
  }
}

/// Coach decides whether this member may book their own sessions.
class _SelfBookSwitch extends StatefulWidget {
  const _SelfBookSwitch({required this.memberId});
  final String memberId;

  @override
  State<_SelfBookSwitch> createState() => _SelfBookSwitchState();
}

class _SelfBookSwitchState extends State<_SelfBookSwitch> {
  bool? _value;

  @override
  void initState() {
    super.initState();
    db
        .from('member_profiles')
        .select('can_self_book')
        .eq('id', widget.memberId)
        .maybeSingle()
        .then((r) {
      if (mounted) setState(() => _value = r?['can_self_book'] != false);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Member can book their own sessions'),
      subtitle: Text(_value == false
          ? 'Off: you book their sessions for them (Schedule tab).'
          : 'On: they book from their app.'),
      value: _value ?? true,
      onChanged: _value == null
          ? null
          : (v) async {
              final ok = await attempt(context, () async {
                await db.rpc('set_can_self_book',
                    params: {'p_member': widget.memberId, 'p_value': v});
              });
              if (ok && mounted) setState(() => _value = v);
            },
    );
  }
}

// ------------------------------------------------------------- evaluations

class _Evaluations extends StatefulWidget {
  const _Evaluations({required this.memberId});
  final String memberId;

  @override
  State<_Evaluations> createState() => _EvaluationsState();
}

class _EvaluationsState extends State<_Evaluations> {
  final _loader = GlobalKey<LoaderState<List<Map<String, dynamic>>>>();

  Future<void> _open(Map<String, dynamic>? existing) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) =>
            EvaluationForm(memberId: widget.memberId, existing: existing)));
    if (saved == true) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Loader<List<Map<String, dynamic>>>(
        key: _loader,
        load: () => loadEvaluations(widget.memberId),
        builder: (context, rows, reload) =>
            EvaluationList(rows: rows, onEdit: _open),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(null),
        icon: const Icon(Icons.add),
        label: const Text('New evaluation'),
      ),
    );
  }
}
