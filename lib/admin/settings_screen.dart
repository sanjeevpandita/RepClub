import 'package:flutter/material.dart';

import '../shared/common.dart';

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Gym'),
            Tab(text: 'Special days'),
            Tab(text: 'Notifications'),
          ]),
        ),
        body: const TabBarView(children: [
          _GymTab(),
          _SpecialDaysTab(),
          _NotificationsTab(),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ gym

class _GymTab extends StatelessWidget {
  const _GymTab();

  @override
  Widget build(BuildContext context) {
    return Loader<Map<String, dynamic>>(
      load: () async => await db.from('app_settings').select().single(),
      builder: (context, data, reload) => ListView(
        padding: const EdgeInsets.all(16),
        children: [_GymForm(data: data)],
      ),
    );
  }
}

class _GymForm extends StatefulWidget {
  const _GymForm({required this.data});
  final Map<String, dynamic> data;

  @override
  State<_GymForm> createState() => _GymFormState();
}

class _GymFormState extends State<_GymForm> {
  late final Set<int> _days = {
    for (final d in (widget.data['open_weekdays'] as List)) d as int
  };
  late int _open = _hour(widget.data['open_time'] as String);
  late int _close = _hour(widget.data['close_time'] as String);
  late final _capacity =
      TextEditingController(text: '${widget.data['slot_capacity']}');
  late final _gymCap =
      TextEditingController(text: '${widget.data['gym_capacity']}');
  late final _lock =
      TextEditingController(text: '${widget.data['cancel_lock_hours']}');
  late final _checkin =
      TextEditingController(text: '${widget.data['checkin_minutes_before']}');
  bool _saving = false;

  static int _hour(String t) => int.parse(t.split(':').first);

  @override
  void dispose() {
    _capacity.dispose();
    _gymCap.dispose();
    _lock.dispose();
    _checkin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final capacity = int.tryParse(_capacity.text.trim());
    final gymCap = int.tryParse(_gymCap.text.trim());
    final lock = int.tryParse(_lock.text.trim());
    final checkin = int.tryParse(_checkin.text.trim());
    String? problem;
    if (_days.isEmpty) {
      problem = 'Choose at least one open day.';
    } else if (_close <= _open) {
      problem = 'Closing time must be after opening time.';
    } else if (capacity == null || capacity < 1) {
      problem = 'Places per session must be 1 or more.';
    } else if (gymCap == null || gymCap < 1) {
      problem = 'Members in the gym at one time must be 1 or more.';
    } else if (lock == null || lock < 0) {
      problem = 'Enter the cancellation lock in hours (0 or more).';
    } else if (checkin == null || checkin < 0) {
      problem = 'Enter the check-in window in minutes (0 or more).';
    }
    if (problem != null) {
      snack(context, problem);
      return;
    }
    setState(() => _saving = true);
    final ok = await attempt(context, () async {
      await db.from('app_settings').update({
        'open_weekdays': (_days.toList()..sort()),
        'open_time': '${two(_open)}:00',
        'close_time': '${two(_close)}:00',
        'slot_capacity': capacity,
        'gym_capacity': gymCap,
        'cancel_lock_hours': lock,
        'checkin_minutes_before': checkin,
      }).eq('id', true);
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) snack(context, 'Saved');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = SizedBox(height: 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Open days', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (var d = 1; d <= 7; d++)
            FilterChip(
              label: Text(_dayNames[d - 1]),
              selected: _days.contains(d),
              onSelected: (on) =>
                  setState(() => on ? _days.add(d) : _days.remove(d)),
            ),
        ]),
        gap,
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _open,
              decoration: const InputDecoration(
                  labelText: 'Opens', border: OutlineInputBorder()),
              items: [
                for (var h = 0; h <= 22; h++)
                  DropdownMenuItem(value: h, child: Text('${two(h)}:00')),
              ],
              onChanged: (v) => setState(() => _open = v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _close,
              decoration: const InputDecoration(
                  labelText: 'Closes', border: OutlineInputBorder()),
              items: [
                for (var h = 1; h <= 23; h++)
                  DropdownMenuItem(value: h, child: Text('${two(h)}:00')),
              ],
              onChanged: (v) => setState(() => _close = v!),
            ),
          ),
        ]),
        gap,
        TextField(
          controller: _capacity,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Places per session (new sessions)',
              border: OutlineInputBorder()),
        ),
        gap,
        TextField(
          controller: _gymCap,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Members in the gym at one time',
              helperText:
                  'Gym bookings and coached sessions both count; coaches do not',
              border: OutlineInputBorder()),
        ),
        gap,
        TextField(
          controller: _lock,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Members cannot cancel within (hours)',
              border: OutlineInputBorder()),
        ),
        gap,
        TextField(
          controller: _checkin,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Check-in opens before start (minutes)',
              border: OutlineInputBorder()),
        ),
        gap,
        InputDecorator(
          decoration: const InputDecoration(
              labelText: 'Timezone', border: OutlineInputBorder()),
          child: Text(widget.data['gym_timezone'] as String),
        ),
        const SizedBox(height: 8),
        Text(
          'Changes apply to sessions created from now on. Sessions that '
          'already exist keep their current places.',
          style: theme.textTheme.bodySmall,
        ),
        gap,
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- special days

class _SpecialDaysTab extends StatelessWidget {
  const _SpecialDaysTab();

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final now = DateTime.now();
        final rows = await db
            .from('gym_day_overrides')
            .select()
            .gte('day', isoDate(DateTime(now.year, now.month, now.day)))
            .order('day');
        return List<Map<String, dynamic>>.from(rows);
      },
      builder: (context, rows, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add special day'),
            onPressed: () async {
              final done = await showDialog<bool>(
                  context: context, builder: (_) => const _AddOverrideDialog());
              if (done == true) reload();
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Close the gym on a usual open day, or open it on a usual closed '
              'day. This only affects sessions generated afterwards; sessions '
              'and bookings that already exist are not removed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No upcoming special days.'))),
          for (final r in rows)
            ListTile(
              leading: Icon((r['is_open'] as bool)
                  ? Icons.lock_open_outlined
                  : Icons.block),
              title: Text(
                  '${showIso(r['day'] as String)}  ·  ${(r['is_open'] as bool) ? 'Open' : 'Closed'}'),
              subtitle: (r['note'] as String?)?.isNotEmpty ?? false
                  ? Text(r['note'] as String)
                  : null,
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await attempt(context, () async {
                    await db
                        .from('gym_day_overrides')
                        .delete()
                        .eq('day', r['day'] as String);
                  });
                  if (ok) reload();
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AddOverrideDialog extends StatefulWidget {
  const _AddOverrideDialog();

  @override
  State<_AddOverrideDialog> createState() => _AddOverrideDialogState();
}

class _AddOverrideDialogState extends State<_AddOverrideDialog> {
  DateTime _day = DateTime.now();
  bool _open = false;
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _day = d);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await attempt(context, () async {
      await db.from('gym_day_overrides').upsert({
        'day': isoDate(_day),
        'is_open': _open,
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add special day'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: _pick,
            child: InputDecorator(
              decoration: const InputDecoration(
                  labelText: 'Date', border: OutlineInputBorder()),
              child: Text(
                  '${_dayNames[_day.weekday - 1]} ${showDate(_day)}'),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Closed')),
              ButtonSegment(value: true, label: Text('Open')),
            ],
            selected: {_open},
            onSelectionChanged: (s) => setState(() => _open = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. Bank holiday',
                border: OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// -------------------------------------------------------- notifications

class _NotificationsTab extends StatelessWidget {
  const _NotificationsTab();

  static String _unit(String type) => switch (type) {
        'LOW_CREDIT' => 'credits left',
        'PACKAGE_EXPIRY' => 'days before expiry',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final rows =
            await db.from('notification_settings').select().order('type');
        return List<Map<String, dynamic>>.from(rows);
      },
      builder: (context, rows, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              'Choose which reminders members receive. These switches are '
              'saved now; the reminders themselves are sent once the member '
              'app and its notifications are built.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final r in rows)
            Column(children: [
              SwitchListTile(
                title: Text(r['label'] as String),
                subtitle: r['threshold'] == null
                    ? null
                    : Text('${r['threshold']} ${_unit(r['type'] as String)}'),
                value: r['enabled'] as bool,
                onChanged: (v) async {
                  final ok = await attempt(context, () async {
                    await db
                        .from('notification_settings')
                        .update({'enabled': v}).eq('type', r['type'] as String);
                  });
                  if (ok) reload();
                },
              ),
              if (r['threshold'] != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      final n = await showDialog<int>(
                        context: context,
                        builder: (_) => _ThresholdDialog(
                            label: r['label'] as String,
                            unit: _unit(r['type'] as String),
                            value: r['threshold'] as int),
                      );
                      if (n == null || !context.mounted) return;
                      final ok = await attempt(context, () async {
                        await db
                            .from('notification_settings')
                            .update({'threshold': n}).eq(
                                'type', r['type'] as String);
                      });
                      if (ok) reload();
                    },
                    child: const Text('Change level'),
                  ),
                ),
            ]),
        ],
      ),
    );
  }
}

class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog(
      {required this.label, required this.unit, required this.value});
  final String label;
  final String unit;
  final int value;

  @override
  State<_ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<_ThresholdDialog> {
  late final _c = TextEditingController(text: '${widget.value}');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.label),
      content: TextField(
        controller: _c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
            labelText: 'Send at (${widget.unit})',
            border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final n = int.tryParse(_c.text.trim());
            if (n == null || n < 1) {
              snack(context, 'Enter a number of 1 or more');
              return;
            }
            Navigator.of(context).pop(n);
          },
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
