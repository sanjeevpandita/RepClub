import 'package:flutter/material.dart';

import '../coach/workout_form.dart';
import 'common.dart';
import 'exercise_media.dart';

const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String todayIso() => isoDate(DateTime.now());

/// "Tue 03/11/2026"
String showDay(String iso) {
  final d = DateTime.parse(iso);
  return '${weekdayNames[d.weekday - 1]} ${showDate(d)}';
}

String fmtKg(num? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

/// "3 x 10 @ 20 kg"
String targetText(Map<String, dynamic> pe) {
  final sets = pe['target_sets'];
  final reps = pe['target_reps'];
  final kg = pe['target_weight_kg'] as num?;
  return [
    '$sets ${sets == 1 ? 'set' : 'sets'}',
    if (reps != null) 'x $reps reps',
    if (kg != null) '@ ${fmtKg(kg)} kg',
  ].join(' ');
}

// ------------------------------------------------------------------- lists

/// A member's workouts, with how many sets are planned and how many logged.
Future<List<Map<String, dynamic>>> loadPlans(String memberId) async {
  final rows =
      await db
              .from('workout_plans')
              .select(
                'id, plan_date, series_id, notes, muscle_groups(name), '
                'workout_plan_exercises(target_sets, workout_set_logs(id))',
              )
              .eq('member_id', memberId)
              .order('plan_date', ascending: true)
          as List;
  return [
    for (final r in rows.cast<Map<String, dynamic>>())
      {
        ...r,
        'group': (r['muscle_groups'] as Map?)?['name'] ?? 'Workout',
        'exercises': (r['workout_plan_exercises'] as List).length,
        'planned': (r['workout_plan_exercises'] as List).fold<int>(
          0,
          (s, e) => s + (e['target_sets'] as int),
        ),
        'done': (r['workout_plan_exercises'] as List).fold<int>(
          0,
          (s, e) => s + (e['workout_set_logs'] as List).length,
        ),
      },
  ];
}

/// Upcoming workouts first (soonest at the top), then past ones (latest first).
class WorkoutPlanList extends StatefulWidget {
  const WorkoutPlanList({
    super.key,
    required this.memberId,
    required this.canManage,
  });
  final String memberId;
  final bool canManage; // coach/admin: may assign, change and remove

  @override
  State<WorkoutPlanList> createState() => _WorkoutPlanListState();
}

class _WorkoutPlanListState extends State<WorkoutPlanList> {
  final _loader = GlobalKey<LoaderState<List<Map<String, dynamic>>>>();

  Future<void> _open(String planId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            WorkoutPlanScreen(planId: planId, canManage: widget.canManage),
      ),
    );
    _loader.currentState?.reload();
  }

  Future<void> _assign() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkoutForm(memberId: widget.memberId)),
    );
    if (saved == true) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Loader<List<Map<String, dynamic>>>(
        key: _loader,
        load: () => loadPlans(widget.memberId),
        builder: (context, rows, reload) {
          final today = todayIso();
          final upcoming = rows
              .where((r) => (r['plan_date'] as String).compareTo(today) >= 0)
              .toList();
          final past = rows
              .where((r) => (r['plan_date'] as String).compareTo(today) < 0)
              .toList()
              .reversed
              .toList();
          if (rows.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 80),
                Center(
                  child: Text(
                    widget.canManage
                        ? 'No workouts yet. Tap "Assign workout".'
                        : 'Your coach has not given you a workout yet.',
                  ),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              _heading(context, 'Coming up'),
              if (upcoming.isEmpty)
                const ListTile(title: Text('Nothing planned')),
              for (final r in upcoming) _tile(context, r, today),
              if (past.isNotEmpty) _heading(context, 'Past'),
              for (final r in past) _tile(context, r, today),
            ],
          );
        },
      ),
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              onPressed: _assign,
              icon: const Icon(Icons.add),
              label: const Text('Assign workout'),
            )
          : null,
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _tile(BuildContext context, Map<String, dynamic> r, String today) {
    final theme = Theme.of(context);
    final done = r['done'] as int;
    final planned = r['planned'] as int;
    final complete = planned > 0 && done >= planned;
    final isToday = r['plan_date'] == today;
    return ListTile(
      leading: Icon(
        complete ? Icons.check_circle : Icons.fitness_center,
        color: complete || isToday ? theme.colorScheme.primary : null,
      ),
      title: Text(
        '${r['group']}  ·  ${isToday ? 'Today' : showDay(r['plan_date'])}',
      ),
      subtitle: Text(
        '${r['exercises']} exercises  ·  $done of $planned sets done',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(r['id'] as String),
    );
  }
}

// ------------------------------------------------------------- one workout

Future<Map<String, dynamic>?> loadPlan(String planId) async {
  final p = await db
      .from('workout_plans')
      .select(
        'id, member_id, plan_date, series_id, notes, muscle_group_id, '
        'muscle_groups(name), '
        'workout_plan_exercises(id, exercise_id, sort_order, target_sets, '
        'target_reps, target_weight_kg, notes, exercises(name, notes, video_url, image_urls), '
        'workout_set_logs(id, set_no, reps, weight_kg))',
      )
      .eq('id', planId)
      .maybeSingle();
  if (p == null) return null;
  final ex = (p['workout_plan_exercises'] as List).cast<Map<String, dynamic>>()
    ..sort(
      (a, b) => (a['sort_order'] as int).compareTo(b['sort_order'] as int),
    );
  final later =
      await db
              .from('workout_plans')
              .select('id')
              .eq('series_id', p['series_id'])
              .gt('plan_date', p['plan_date'])
          as List;
  return {...p, 'workout_plan_exercises': ex, 'later_weeks': later.length};
}

/// One workout: the exercises and targets, and the sets logged so far.
class WorkoutPlanScreen extends StatefulWidget {
  const WorkoutPlanScreen({
    super.key,
    required this.planId,
    required this.canManage,
  });
  final String planId;
  final bool canManage;

  @override
  State<WorkoutPlanScreen> createState() => _WorkoutPlanScreenState();
}

class _WorkoutPlanScreenState extends State<WorkoutPlanScreen> {
  final _loader = GlobalKey<LoaderState<Map<String, dynamic>?>>();
  Map<String, dynamic>? _plan;

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WorkoutForm(
          memberId: _plan!['member_id'] as String,
          existing: _plan,
        ),
      ),
    );
    if (saved == true) _loader.currentState?.reload();
  }

  Future<void> _delete() async {
    final later = _plan!['later_weeks'] as int;
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this workout?'),
        content: Text(
          later == 0
              ? 'Any sets already logged for it are removed too.'
              : 'It repeats for $later more ${later == 1 ? 'week' : 'weeks'} after this one. '
                    'Any sets already logged are removed too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep'),
          ),
          if (later > 0)
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('This and later weeks'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(later > 0 ? 'Only this day' : 'Remove'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc(
        'delete_workout_plan',
        params: {'p_plan': widget.planId, 'p_following': choice},
      );
    });
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          p == null
              ? 'Workout'
              : '${(p['muscle_groups'] as Map?)?['name'] ?? 'Workout'} · ${showDay(p['plan_date'])}',
        ),
        actions: [
          if (widget.canManage && p != null) ...[
            IconButton(
              tooltip: 'Change',
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: Loader<Map<String, dynamic>?>(
        key: _loader,
        load: () async {
          final d = await loadPlan(widget.planId);
          if (mounted) setState(() => _plan = d);
          return d;
        },
        builder: (context, d, reload) {
          if (d == null) {
            return ListView(
              children: const [
                SizedBox(height: 80),
                Center(child: Text('This workout was removed.')),
              ],
            );
          }
          final canLog = (d['plan_date'] as String).compareTo(todayIso()) <= 0;
          final ex = d['workout_plan_exercises'] as List<Map<String, dynamic>>;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              if ((d['notes'] as String?)?.isNotEmpty ?? false)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sticky_note_2_outlined),
                    title: Text(d['notes'] as String),
                    subtitle: const Text('Note from your coach'),
                  ),
                ),
              if ((d['later_weeks'] as int) > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'Repeats every week, ${d['later_weeks']} more after this one.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!canLog)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'Sets can be ticked off from the day of the workout.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final pe in ex)
                _ExerciseCard(
                  key: ValueKey(pe['id']),
                  pe: pe,
                  memberId: d['member_id'] as String,
                  canLog: canLog,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ExerciseCard extends StatefulWidget {
  const _ExerciseCard({
    super.key,
    required this.pe,
    required this.memberId,
    required this.canLog,
  });
  final Map<String, dynamic> pe;
  final String memberId;
  final bool canLog;

  @override
  State<_ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends State<_ExerciseCard> {
  late final Map<int, Map<String, dynamic>> _logs = {
    for (final l
        in (widget.pe['workout_set_logs'] as List).cast<Map<String, dynamic>>())
      l['set_no'] as int: l,
  };
  late int _rows = [
    widget.pe['target_sets'] as int,
    ..._logs.keys,
  ].reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ex = widget.pe['exercises'] as Map? ?? {};
    final notes = (widget.pe['notes'] as String?) ?? ''; // coach's tip
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Tap the photo or name to see how to do the exercise.
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => showExerciseHowTo(context, ex),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          if (imageList(ex['image_urls']).isNotEmpty) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: ExerciseImage(
                                  url: imageList(ex['image_urls']).first,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Flexible(
                            child: Text(
                              ex['name'] as String? ?? 'Exercise',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Text(
                  '${_logs.length}/${widget.pe['target_sets']}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: _logs.length >= (widget.pe['target_sets'] as int)
                        ? theme.colorScheme.primary
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            Text(
              'Target: ${targetText(widget.pe)}',
              style: theme.textTheme.bodyMedium,
            ),
            if (notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Tip: $notes', style: theme.textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ExerciseHelpButtons(exercise: ex),
            ),
            const SizedBox(height: 8),
            for (var i = 1; i <= _rows; i++)
              _SetRow(
                key: ValueKey('${widget.pe['id']}-$i'),
                setNo: i,
                planExerciseId: widget.pe['id'] as String,
                memberId: widget.memberId,
                targetReps: widget.pe['target_reps'] as int?,
                targetKg: widget.pe['target_weight_kg'] as num?,
                log: _logs[i],
                enabled: widget.canLog,
                onChanged: (log) => setState(() {
                  if (log == null) {
                    _logs.remove(i);
                  } else {
                    _logs[i] = log;
                  }
                }),
              ),
            if (widget.canLog && _rows < 20)
              TextButton.icon(
                onPressed: () => setState(() => _rows++),
                icon: const Icon(Icons.add),
                label: const Text('Add a set'),
              ),
          ],
        ),
      ),
    );
  }
}

/// One set: reps and kg boxes and a tick. Ticking saves it; unticking removes it.
class _SetRow extends StatefulWidget {
  const _SetRow({
    super.key,
    required this.setNo,
    required this.planExerciseId,
    required this.memberId,
    required this.targetReps,
    required this.targetKg,
    required this.log,
    required this.enabled,
    required this.onChanged,
  });
  final int setNo;
  final String planExerciseId;
  final String memberId;
  final int? targetReps;
  final num? targetKg;
  final Map<String, dynamic>? log;
  final bool enabled;
  final void Function(Map<String, dynamic>? log) onChanged;

  @override
  State<_SetRow> createState() => _SetRowState();
}

class _SetRowState extends State<_SetRow> {
  late final _reps = TextEditingController(
    text: '${widget.log?['reps'] ?? widget.targetReps ?? ''}',
  );
  late final _kgCtl = TextEditingController(
    text: fmtKg(widget.log?['weight_kg'] as num? ?? widget.targetKg),
  );
  late bool _done = widget.log != null;
  bool _busy = false;

  @override
  void dispose() {
    _reps.dispose();
    _kgCtl.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (_done) {
      setState(() => _busy = true);
      final ok = await attempt(context, () async {
        await db
            .from('workout_set_logs')
            .delete()
            .eq('plan_exercise_id', widget.planExerciseId)
            .eq('set_no', widget.setNo);
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (ok) _done = false;
      });
      if (ok) widget.onChanged(null);
      return;
    }
    final reps = _reps.text.trim().isEmpty
        ? null
        : int.tryParse(_reps.text.trim());
    final kgText = _kgCtl.text.trim().replaceAll(',', '.');
    final kg = kgText.isEmpty ? null : double.tryParse(kgText);
    if ((_reps.text.trim().isNotEmpty && (reps == null || reps < 0)) ||
        (kgText.isNotEmpty && (kg == null || kg < 0))) {
      snack(context, 'Enter numbers such as 10 reps and 22.5 kg');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final row = {
      'plan_exercise_id': widget.planExerciseId,
      'member_id': widget.memberId,
      'set_no': widget.setNo,
      'reps': reps,
      'weight_kg': kg,
    };
    final ok = await attempt(context, () async {
      await db
          .from('workout_set_logs')
          .upsert(row, onConflict: 'plan_exercise_id,set_no');
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _done = true;
    });
    if (ok) widget.onChanged(row);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editable = widget.enabled && !_done && !_busy;
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              'Set ${widget.setNo}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _reps,
              enabled: editable,
              keyboardType: TextInputType.number,
              decoration: deco('Reps'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _kgCtl,
              enabled: editable,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: deco('kg'),
            ),
          ),
          IconButton(
            tooltip: _done ? 'Done (tap to undo)' : 'Mark as done',
            onPressed: widget.enabled ? _toggle : null,
            iconSize: 32,
            icon: _busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _done ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: _done ? theme.colorScheme.primary : null,
                  ),
          ),
        ],
      ),
    );
  }
}
