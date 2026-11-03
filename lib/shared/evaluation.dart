import 'package:flutter/material.dart';

import 'body_map.dart';
import 'common.dart';

/// One measured value of a Full Body Evaluation (column name, label, unit).
typedef EvalField = ({String key, String label, String unit});

const evalComposition = <EvalField>[
  (key: 'weight_kg', label: 'Weight', unit: 'kg'),
  (key: 'body_fat_pct', label: 'Body fat', unit: '%'),
  (key: 'lean_weight_kg', label: 'Lean body weight', unit: 'kg'),
  (key: 'fat_weight_kg', label: 'Body fat weight', unit: 'kg'),
];

const evalCaliper = <EvalField>[
  (key: 'suprailiac_mm', label: 'Suprailiac', unit: 'mm'),
  (key: 'bicep_mm', label: 'Bicep', unit: 'mm'),
  (key: 'tricep_mm', label: 'Tricep', unit: 'mm'),
  (key: 'subscapular_mm', label: 'Subscapular', unit: 'mm'),
];

const evalTape = <EvalField>[
  (key: 'bicep_right_cm', label: 'Bicep right', unit: 'cm'),
  (key: 'bicep_left_cm', label: 'Bicep left', unit: 'cm'),
  (key: 'forearm_right_cm', label: 'Forearm right', unit: 'cm'),
  (key: 'forearm_left_cm', label: 'Forearm left', unit: 'cm'),
  (key: 'thigh_upper_right_cm', label: 'Thigh upper right', unit: 'cm'),
  (key: 'thigh_upper_left_cm', label: 'Thigh upper left', unit: 'cm'),
  (key: 'thigh_mid_right_cm', label: 'Thigh mid right', unit: 'cm'),
  (key: 'thigh_mid_left_cm', label: 'Thigh mid left', unit: 'cm'),
  (key: 'calf_right_cm', label: 'Calf right', unit: 'cm'),
  (key: 'calf_left_cm', label: 'Calf left', unit: 'cm'),
  (key: 'neck_cm', label: 'Neck', unit: 'cm'),
  (key: 'chest_cm', label: 'Chest', unit: 'cm'),
  (key: 'shoulders_cm', label: 'Shoulders', unit: 'cm'),
  (key: 'waist_cm', label: 'Waist', unit: 'cm'),
  (key: 'hips_cm', label: 'Hips', unit: 'cm'),
];

/// Drops trailing zeros: 62.38 -> "62.38", 8.0 -> "8", 30.5 -> "30.5".
String evalNumber(Object v) {
  final s = double.parse(v.toString()).toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Read-only view of one evaluation (used by coach and member).
class EvaluationView extends StatelessWidget {
  const EvaluationView(
      {super.key, required this.data, this.previous, this.coachName});
  final Map<String, dynamic> data;
  final Map<String, dynamic>? previous;
  final String? coachName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String title, List<EvalField> fields) {
      final shown = [for (final f in fields) if (data[f.key] != null) f];
      if (shown.isEmpty) return const SizedBox.shrink();
      return Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),
              for (final f in shown)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(f.label)),
                      Text('${evalNumber(data[f.key])} ${f.unit}',
                          style: theme.textTheme.titleSmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final method = data['method'] as String?;
    final notes = data['notes'] as String?;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(showIso(data['evaluated_on'] as String),
            style: theme.textTheme.headlineSmall),
        if (method != null && method.isNotEmpty) Text('Method: $method'),
        if (coachName != null && coachName!.isNotEmpty)
          Text('Evaluated by $coachName'),
        if (evalTape.any((f) => data[f.key] != null))
          Card(
            margin: const EdgeInsets.only(top: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Body map',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: theme.colorScheme.primary)),
                  Text(
                    previous == null
                        ? 'Each arrow points to where the measurement was taken.'
                        : 'Each arrow points to where the measurement was taken.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  BodyMap(data: data, previous: previous),
                ],
              ),
            ),
          ),
        section('Body composition', evalComposition),
        section('Caliper measurements', evalCaliper),
        section('Tape measurements', evalTape),
        if (notes != null && notes.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(notes),
            ),
          ),
      ],
    );
  }
}

/// List of a member's evaluations, newest first. Tapping opens the full sheet.
/// [onEdit] (coach) adds an Edit button to the opened sheet.
class EvaluationList extends StatelessWidget {
  const EvaluationList({
    super.key,
    required this.rows,
    this.onEdit,
    this.names = const {},
  });
  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic>)? onEdit;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 80),
        Center(child: Text('No body evaluations yet')),
      ]);
    }
    return ListView(
      children: [
        for (var n = 0; n < rows.length; n++)
          Builder(builder: (context) {
            final r = rows[n];
            final prev = n + 1 < rows.length ? rows[n + 1] : null;
            return ListTile(
            leading: const Icon(Icons.monitor_weight_outlined),
            title: Text(showIso(r['evaluated_on'] as String)),
            subtitle: Text([
              if (r['weight_kg'] != null) '${evalNumber(r['weight_kg'])} kg',
              if (r['body_fat_pct'] != null)
                '${evalNumber(r['body_fat_pct'])}% body fat',
            ].join(' - ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (ctx) => Scaffold(
                appBar: AppBar(
                  title: const Text('Body evaluation'),
                  actions: [
                    if (onEdit != null)
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          onEdit!(r);
                        },
                      ),
                  ],
                ),
                body: EvaluationView(
                    data: r, previous: prev, coachName: names[r['coach_id']]),
              ),
            )),
            );
          }),
      ],
    );
  }
}

Future<List<Map<String, dynamic>>> loadEvaluations(String memberId) async {
  final rows = await db
      .from('body_evaluations')
      .select()
      .eq('member_id', memberId)
      .order('evaluated_on', ascending: false)
      .order('created_at', ascending: false) as List;
  return rows.cast<Map<String, dynamic>>();
}
