import 'package:flutter/material.dart';

import '../shared/common.dart';
import '../shared/evaluation.dart';

/// Coach records (or edits) a Full Body Evaluation for one member.
class EvaluationForm extends StatefulWidget {
  const EvaluationForm({super.key, required this.memberId, this.existing});
  final String memberId;
  final Map<String, dynamic>? existing;

  @override
  State<EvaluationForm> createState() => _EvaluationFormState();
}

class _EvaluationFormState extends State<EvaluationForm> {
  late DateTime _date;
  final _method = TextEditingController();
  final _notes = TextEditingController();
  final _c = <String, TextEditingController>{};
  bool _saving = false;

  static const _autoKeys = {'lean_weight_kg', 'fat_weight_kg'};

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e == null ? DateTime.now() : DateTime.parse(e['evaluated_on']);
    _method.text = (e?['method'] as String?) ?? 'Durnin/Womersley';
    _notes.text = (e?['notes'] as String?) ?? '';
    for (final f in [...evalComposition, ...evalCaliper, ...evalTape]) {
      _c[f.key] = TextEditingController(
          text: e?[f.key] == null ? '' : evalNumber(e![f.key]));
    }
    _c['weight_kg']!.addListener(_recalc);
    _c['body_fat_pct']!.addListener(_recalc);
  }

  @override
  void dispose() {
    _method.dispose();
    _notes.dispose();
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _num(String key) =>
      double.tryParse(_c[key]!.text.trim().replaceAll(',', '.'));

  /// Fat weight = weight x body fat %; lean = weight - fat weight.
  void _recalc() {
    final w = _num('weight_kg');
    final bf = _num('body_fat_pct');
    if (w == null || bf == null) return;
    final fat = w * bf / 100;
    _c['fat_weight_kg']!.text = fat.toStringAsFixed(2);
    _c['lean_weight_kg']!.text = (w - fat).toStringAsFixed(2);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _save() async {
    final row = <String, dynamic>{
      'member_id': widget.memberId,
      'evaluated_on': isoDate(_date),
      'method': _method.text.trim().isEmpty ? null : _method.text.trim(),
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    var any = false;
    for (final f in [...evalComposition, ...evalCaliper, ...evalTape]) {
      final text = _c[f.key]!.text.trim();
      if (text.isEmpty) {
        row[f.key] = null;
        continue;
      }
      final v = _num(f.key);
      if (v == null) {
        snack(context, '${f.label}: "$text" is not a number');
        return;
      }
      row[f.key] = v;
      any = true;
    }
    if (!any) {
      snack(context, 'Enter at least one measurement');
      return;
    }
    setState(() => _saving = true);
    final id = widget.existing?['id'];
    final ok = await attempt(context, () async {
      if (id == null) {
        await db.from('body_evaluations').insert(row);
      } else {
        await db.from('body_evaluations').update(row).eq('id', id);
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this evaluation?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Back')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () async {
      await db
          .from('body_evaluations')
          .delete()
          .eq('id', widget.existing!['id']);
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Widget _field(EvalField f) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: _c[f.key],
          readOnly: false,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: f.label,
            suffixText: f.unit,
            border: const OutlineInputBorder(),
            helperText: _autoKeys.contains(f.key)
                ? 'Worked out from weight and body fat (you can change it)'
                : null,
          ),
        ),
      );

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(t,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null
            ? 'New body evaluation'
            : 'Edit body evaluation'),
        actions: [
          if (widget.existing != null)
            IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text('Date: ${showDate(_date)}'),
            trailing: const Icon(Icons.edit_calendar),
            onTap: _pickDate,
          ),
          TextField(
            controller: _method,
            decoration: const InputDecoration(
                labelText: 'Method', border: OutlineInputBorder()),
          ),
          _title('Body composition'),
          for (final f in evalComposition) _field(f),
          _title('Caliper measurements'),
          for (final f in evalCaliper) _field(f),
          _title('Tape measurements'),
          for (final f in evalTape) _field(f),
          const SizedBox(height: 4),
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: const InputDecoration(
                labelText: 'Notes', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            child: Text(_saving ? 'Saving...' : 'Save evaluation'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
