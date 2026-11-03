import 'package:flutter/material.dart';

import '../shared/common.dart';
import '../shared/exercise_media.dart';
import '../shared/workout.dart';

class _Target {
  _Target({int? sets, int? reps, num? kg, String? notes})
      : sets = TextEditingController(text: '${sets ?? 3}'),
        reps = TextEditingController(text: reps == null ? '' : '$reps'),
        kg = TextEditingController(text: fmtKg(kg)),
        notes = TextEditingController(text: notes ?? '');
  final TextEditingController sets, reps, kg, notes;

  void dispose() {
    for (final c in [sets, reps, kg, notes]) {
      c.dispose();
    }
  }
}

/// Coach (or admin): give a member a workout, or change one.
/// [existing] is a plan from [loadPlan] when changing.
class WorkoutForm extends StatefulWidget {
  const WorkoutForm({super.key, required this.memberId, this.existing});
  final String memberId;
  final Map<String, dynamic>? existing;

  @override
  State<WorkoutForm> createState() => _WorkoutFormState();
}

class _WorkoutFormState extends State<WorkoutForm> {
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>> _exercises = [];
  // Last targets this member had for each exercise, to fill in new workouts.
  final Map<String, Map<String, dynamic>> _lastTargets = {};
  String? _error;

  String? _groupId;
  late DateTime _date;
  int _weeks = 1;
  bool _following = false;
  final _notes = TextEditingController();
  final Map<String, _Target> _picked = {};
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _groupId = e['muscle_group_id'] as String;
      _date = DateTime.parse(e['plan_date'] as String);
      _notes.text = (e['notes'] as String?) ?? '';
      for (final pe in (e['workout_plan_exercises'] as List).cast<Map<String, dynamic>>()) {
        _picked[pe['exercise_id'] as String] = _Target(
          sets: pe['target_sets'] as int?,
          reps: pe['target_reps'] as int?,
          kg: pe['target_weight_kg'] as num?,
          notes: pe['notes'] as String?,
        );
      }
    } else {
      final now = DateTime.now();
      _date = DateTime(now.year, now.month, now.day);
    }
    _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    for (final t in _picked.values) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final g = await db
          .from('muscle_groups')
          .select('id, name, is_active')
          .order('sort_order', ascending: true)
          .order('name', ascending: true) as List;
      final x = await db
          .from('exercises')
          .select('id, name, muscle_group_id, is_active, notes, video_url, image_urls')
          .order('sort_order', ascending: true)
          .order('name', ascending: true) as List;
      final last = await db
          .from('workout_plan_exercises')
          .select('exercise_id, target_sets, target_reps, target_weight_kg, '
              'workout_plans!inner(member_id, plan_date)')
          .eq('workout_plans.member_id', widget.memberId) as List;
      final byDate = last.cast<Map<String, dynamic>>()
        ..sort((a, b) => (a['workout_plans']['plan_date'] as String)
            .compareTo(b['workout_plans']['plan_date'] as String));
      for (final r in byDate) {
        _lastTargets[r['exercise_id'] as String] = r; // latest wins
      }
      if (!mounted) return;
      setState(() {
        _groups = [
          for (final r in g.cast<Map<String, dynamic>>())
            if (r['is_active'] == true || r['id'] == _groupId) r
        ];
        _exercises = x.cast<Map<String, dynamic>>();
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the exercises. Go back and try again.');
    }
  }

  List<Map<String, dynamic>> get _groupExercises => [
        for (final e in _exercises)
          if (e['muscle_group_id'] == _groupId &&
              (e['is_active'] == true || _picked.containsKey(e['id'])))
            e
      ];

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        final last = _lastTargets[id];
        _picked[id] = _Target(
          sets: last?['target_sets'] as int?,
          reps: (last?['target_reps'] as int?) ?? 10,
          kg: last?['target_weight_kg'] as num?,
        );
      } else {
        _picked.remove(id)?.dispose();
      }
    });
  }

  void _pickGroup(String id) {
    if (id == _groupId) return;
    setState(() {
      _groupId = id;
      for (final t in _picked.values) {
        t.dispose();
      }
      _picked.clear();
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _save() async {
    if (_groupId == null) {
      snack(context, 'Choose a muscle group');
      return;
    }
    final list = <Map<String, dynamic>>[];
    for (final e in _groupExercises) {
      final t = _picked[e['id']];
      if (t == null) continue;
      final sets = int.tryParse(t.sets.text.trim());
      final repsText = t.reps.text.trim();
      final reps = repsText.isEmpty ? null : int.tryParse(repsText);
      final kgText = t.kg.text.trim().replaceAll(',', '.');
      final kg = kgText.isEmpty ? null : double.tryParse(kgText);
      if (sets == null || sets < 1 || sets > 20) {
        snack(context, '${e['name']}: sets must be 1 to 20');
        return;
      }
      if (repsText.isNotEmpty && (reps == null || reps < 1 || reps > 200)) {
        snack(context, '${e['name']}: reps must be 1 to 200');
        return;
      }
      if (kgText.isNotEmpty && (kg == null || kg < 0)) {
        snack(context, '${e['name']}: enter a weight such as 22.5');
        return;
      }
      list.add({
        'exercise_id': e['id'],
        'sets': sets,
        'reps': reps,
        'weight_kg': kg,
        'notes': t.notes.text.trim(),
      });
    }
    if (list.isEmpty) {
      snack(context, 'Tick at least one exercise');
      return;
    }
    setState(() => _saving = true);
    final ok = await attempt(context, () async {
      if (_isEdit) {
        await db.rpc('update_workout_plan', params: {
          'p_plan': widget.existing!['id'],
          'p_exercises': list,
          'p_notes': _notes.text.trim(),
          'p_following': _following,
          'p_new_date': _following ? null : isoDate(_date),
        });
      } else {
        await db.rpc('assign_workout_plan', params: {
          'p_member': widget.memberId,
          'p_muscle_group': _groupId,
          'p_date': isoDate(_date),
          'p_weeks': _weeks,
          'p_exercises': list,
          'p_notes': _notes.text.trim(),
        });
      }
    });
    if (!mounted) return;
    if (ok) {
      snack(context, _isEdit ? 'Workout changed' : 'Workout assigned');
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final later = (widget.existing?['later_weeks'] as int?) ?? 0;
    final groupName = _groups
        ?.where((g) => g['id'] == _groupId)
        .map((g) => g['name'] as String)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Change workout' : 'Assign workout')),
      body: _groups == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Text('Muscle group', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_isEdit)
                  Text(groupName ?? '', style: theme.textTheme.titleLarge)
                else if (_groups!.isEmpty)
                  const Text('No muscle groups yet. Ask the admin to add them.')
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final g in _groups!)
                      ChoiceChip(
                        label: Text(g['name'] as String),
                        selected: g['id'] == _groupId,
                        onSelected: (_) => _pickGroup(g['id'] as String),
                      ),
                  ]),
                const SizedBox(height: 20),
                if (_isEdit && later > 0)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Also change the next $later ${later == 1 ? 'week' : 'weeks'}'),
                    subtitle: const Text('Off: only this day changes'),
                    value: _following,
                    onChanged: (v) => setState(() => _following = v),
                  ),
                if (!_following)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                        '${_isEdit || _weeks == 1 ? 'Date' : 'First date'}: ${showDay(isoDate(_date))}'),
                  ),
                if (!_isEdit) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _weeks,
                    decoration: const InputDecoration(
                        labelText: 'Repeat', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: 1, child: Text('Just this day')),
                      for (var w = 2; w <= 12; w++)
                        DropdownMenuItem(
                            value: w, child: Text('Same day every week, for $w weeks')),
                    ],
                    onChanged: (v) => setState(() => _weeks = v ?? 1),
                  ),
                  if (_weeks > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(
                          'Last one: ${showDay(isoDate(_date.add(Duration(days: 7 * (_weeks - 1)))))}',
                          style: theme.textTheme.bodySmall),
                    ),
                ],
                const SizedBox(height: 20),
                Text('Exercises', style: theme.textTheme.titleMedium),
                if (_isEdit)
                  Text('Unticking an exercise also removes any sets logged for it.',
                      style: theme.textTheme.bodySmall),
                if (_groupId == null)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Choose a muscle group first.'))
                else if (_groupExercises.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('This group has no exercises yet.')),
                for (final e in _groupExercises) _exerciseTile(e),
                const SizedBox(height: 16),
                TextField(
                  controller: _notes,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Note for the member (optional)',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit
                          ? 'Save changes'
                          : _weeks == 1
                              ? 'Assign workout'
                              : 'Assign for $_weeks weeks'),
                ),
              ],
            ),
    );
  }

  Widget _exerciseTile(Map<String, dynamic> e) {
    final id = e['id'] as String;
    final t = _picked[id];
    InputDecoration deco(String label) => InputDecoration(
        labelText: label, isDense: true, border: const OutlineInputBorder());
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [
        CheckboxListTile(
          value: t != null,
          title: Text(e['name'] as String),
          subtitle: e['is_active'] == true ? null : const Text('Switched off by the admin'),
          secondary: hasHowTo(e) || hasVideo(e)
              ? IconButton(
                  tooltip: 'How to',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => showExerciseHowTo(context, e),
                )
              : null,
          onChanged: (v) => _toggle(id, v ?? false),
        ),
        if (t != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: t.sets,
                        keyboardType: TextInputType.number,
                        decoration: deco('Sets'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: t.reps,
                        keyboardType: TextInputType.number,
                        decoration: deco('Reps'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: t.kg,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: deco('kg'))),
              ]),
              const SizedBox(height: 8),
              TextField(controller: t.notes, decoration: deco('Tip (optional)')),
            ]),
          ),
      ]),
    );
  }
}
