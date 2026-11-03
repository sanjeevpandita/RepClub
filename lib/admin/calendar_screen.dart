import 'package:flutter/material.dart';

import '../shared/common.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayLabel(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${showDate(d)}';

DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

bool _isTaken(String status) =>
    status == 'BOOKED' || status == 'ATTENDED' || status == 'NO_SHOW';

int _takenCount(Map<String, dynamic> slot) =>
    ((slot['bookings'] as List?) ?? [])
        .where((b) => _isTaken((b as Map)['status'] as String))
        .length;

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _day = _dayStart(DateTime.now());
  String? _coachFilter;
  List<Map<String, dynamic>>? _slots;
  Map<String, String> _coachNames = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final start = _day;
      final end = DateTime(_day.year, _day.month, _day.day + 1);
      final rows = await db
          .from('slots')
          .select('id, coach_id, starts_at, capacity, is_cancelled, bookings(status)')
          .gte('starts_at', start.toUtc().toIso8601String())
          .lt('starts_at', end.toUtc().toIso8601String())
          .order('starts_at', ascending: true);
      final coaches =
          await db.from('profiles').select('id, full_name').eq('role', 'COACH');
      if (!mounted) return;
      setState(() {
        _slots = List<Map<String, dynamic>>.from(rows);
        _coachNames = {
          for (final c in coaches)
            c['id'] as String: c['full_name'] as String? ?? ''
        };
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load the calendar. Pull down to retry.');
    }
  }

  void _goTo(DateTime d) {
    setState(() {
      _day = _dayStart(d);
      _slots = null;
    });
    _load();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (d != null) _goTo(d);
  }

  Future<void> _generate() async {
    final done = await showDialog<bool>(
        context: context, builder: (_) => const _GenerateDialog());
    if (done == true) _load();
  }

  Future<void> _addSession() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AddSessionDialog(
          day: _day, coaches: _coachNames, initialCoach: _coachFilter),
    );
    if (done == true) _load();
  }

  Future<void> _openSlot(Map<String, dynamic> slot) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SlotDetailScreen(
        slotId: slot['id'] as String,
        coachName: _coachNames[slot['coach_id']] ?? '',
      ),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = _slots;
    final shown = all
        ?.where((s) => _coachFilter == null || s['coach_id'] == _coachFilter)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'add' ? _addSession() : _generate(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'add', child: Text('Add one-off session')),
              PopupMenuItem(
                  value: 'generate', child: Text('Generate from weekly hours')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _goTo(_day.subtract(const Duration(days: 1))),
              ),
              Expanded(
                child: TextButton(
                  onPressed: _pickDay,
                  child: Text(_dayLabel(_day),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () =>
                    _goTo(DateTime(_day.year, _day.month, _day.day + 1)),
              ),
              TextButton(
                  onPressed: () => _goTo(DateTime.now()),
                  child: const Text('Today')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<String?>(
              initialValue: _coachFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Coach',
                  border: OutlineInputBorder(),
                  isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('All coaches')),
                for (final e in _coachNames.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _coachFilter = v),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: shown == null
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      Center(
                          child: _error == null
                              ? const CircularProgressIndicator()
                              : Text(_error!)),
                    ])
                  : ListView(
                      children: [
                        if (shown.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(
                                  child: Text('No sessions on this day.'))),
                        for (final g in _byTime(shown)) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            child: Text(g.key,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                          ),
                          for (final s in g.value) _slotTile(s),
                          const Divider(height: 8),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Sessions grouped by start time (earliest first); coaches A-Z within a time.
  List<MapEntry<String, List<Map<String, dynamic>>>> _byTime(
      List<Map<String, dynamic>> slots) {
    final sorted = [...slots]..sort((a, b) {
        final t = DateTime.parse(a['starts_at'] as String)
            .compareTo(DateTime.parse(b['starts_at'] as String));
        if (t != 0) return t;
        return (_coachNames[a['coach_id']] ?? '')
            .toLowerCase()
            .compareTo((_coachNames[b['coach_id']] ?? '').toLowerCase());
      });
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final s in sorted) {
      final time = showTime(DateTime.parse(s['starts_at'] as String).toLocal());
      groups.putIfAbsent(time, () => []).add(s);
    }
    return groups.entries.toList();
  }

  Widget _slotTile(Map<String, dynamic> s) {
    final cancelled = s['is_cancelled'] as bool;
    final taken = _takenCount(s);
    final cap = s['capacity'] as int;
    final full = taken >= cap;
    return Opacity(
      opacity: cancelled ? 0.5 : 1,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 32, right: 16),
        title: Text(_coachNames[s['coach_id']] ?? '',
            style: Theme.of(context).textTheme.bodyLarge),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LinearProgressIndicator(
              value: cap == 0 ? 0 : (taken / cap).clamp(0, 1).toDouble()),
        ),
        trailing: Text(
          cancelled ? 'Cancelled' : (full ? 'Full $taken/$cap' : '$taken/$cap'),
        ),
        onTap: () => _openSlot(s),
      ),
    );
  }
}

class _AddSessionDialog extends StatefulWidget {
  const _AddSessionDialog(
      {required this.day, required this.coaches, this.initialCoach});
  final DateTime day;
  final Map<String, String> coaches;
  final String? initialCoach;

  @override
  State<_AddSessionDialog> createState() => _AddSessionDialogState();
}

class _AddSessionDialogState extends State<_AddSessionDialog> {
  late String? _coach = widget.initialCoach;
  late DateTime _day = widget.day;
  int _hour = 9;
  int _openHour = 6;
  int _closeHour = 20;
  int _capacity = 10;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    db
        .from('app_settings')
        .select('open_time, close_time, slot_capacity')
        .single()
        .then((s) {
      if (!mounted) return;
      setState(() {
        _openHour = int.parse((s['open_time'] as String).split(':').first);
        _closeHour = int.parse((s['close_time'] as String).split(':').first);
        _capacity = s['slot_capacity'] as int;
        _hour = _hour.clamp(_openHour, _closeHour - 1);
      });
    }).catchError((_) {});
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _day = d);
  }

  Future<void> _save() async {
    if (_coach == null) {
      snack(context, 'Choose a coach');
      return;
    }
    final start = DateTime(_day.year, _day.month, _day.day, _hour);
    setState(() => _busy = true);
    final ok = await attempt(context, () async {
      await db.from('slots').insert({
        'coach_id': _coach,
        'starts_at': start.toUtc().toIso8601String(),
        'ends_at': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
        'capacity': _capacity,
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
      title: const Text('Add one-off session'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _coach,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Coach', border: OutlineInputBorder()),
              items: [
                for (final e in widget.coaches.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _coach = v),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDay,
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Date', border: OutlineInputBorder()),
                child: Text(_dayLabel(_day)),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _hour,
              decoration: const InputDecoration(
                  labelText: 'Starts at', border: OutlineInputBorder()),
              items: [
                for (var h = _openHour; h < _closeHour; h++)
                  DropdownMenuItem(value: h, child: Text('${two(h)}:00')),
              ],
              onChanged: (v) => setState(() => _hour = v!),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Add session'),
        ),
      ],
    );
  }
}

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog();

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  DateTime _from = _dayStart(DateTime.now());
  late DateTime _to = _from.add(const Duration(days: 13));
  bool _busy = false;

  Future<void> _pick(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() => isFrom ? _from = d : _to = d);
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    int? n;
    final ok = await attempt(context, () async {
      n = await db.rpc('admin_generate_slots',
          params: {'p_from': isoDate(_from), 'p_to': isoDate(_to)}) as int;
    });
    if (!mounted) return;
    if (ok) {
      snack(context, '${n ?? 0} new sessions created');
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate sessions'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'Creates sessions from each coach\'s weekly schedule, on open '
              'days only. Existing sessions are left alone. Up to 62 days.'),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('From'),
            trailing: Text(showDate(_from)),
            onTap: () => _pick(true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('To'),
            trailing: Text(showDate(_to)),
            onTap: () => _pick(false),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _run,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Generate'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ slot detail

class SlotDetailScreen extends StatefulWidget {
  const SlotDetailScreen(
      {super.key, required this.slotId, required this.coachName});
  final String slotId;
  final String coachName;

  @override
  State<SlotDetailScreen> createState() => _SlotDetailScreenState();
}

class _SlotDetailScreenState extends State<SlotDetailScreen> {
  final _key = GlobalKey<LoaderState<_SlotData>>();

  Future<_SlotData> _load() async {
    final slot = await db.from('slots').select().eq('id', widget.slotId).single();
    final rows = await db
        .from('bookings')
        .select('id, status, member_id')
        .eq('slot_id', widget.slotId)
        .order('created_at', ascending: true);
    final ids = [for (final r in rows) r['member_id'] as String];
    final names = <String, String>{};
    if (ids.isNotEmpty) {
      final pr =
          await db.from('profiles').select('id, full_name').inFilter('id', ids);
      for (final p in pr) {
        names[p['id'] as String] = p['full_name'] as String? ?? '';
      }
    }
    return _SlotData(slot, List<Map<String, dynamic>>.from(rows), names);
  }

  Future<void> _addMember(_SlotData d) async {
    final picked = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => _MemberPicker(
        coachId: d.slot['coach_id'] as String,
        coachName: widget.coachName,
        excluding: {
          for (final b in d.bookings)
            if (_isTaken(b['status'] as String)) b['member_id'] as String
        },
      ),
    ));
    if (picked == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('create_booking',
          params: {'p_slot': widget.slotId, 'p_member': picked});
    });
    if (ok) _key.currentState?.reload();
  }

  Future<void> _cancel(Map<String, dynamic> b) async {
    final r = await showDialog<ReasonResult>(
      context: context,
      builder: (_) => const ReasonDialog(
          title: 'Cancel booking', confirm: 'Cancel booking'),
    );
    if (r == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('cancel_booking', params: {
        'p_booking': b['id'],
        'p_reason': r.reason,
        'p_note': r.note.isEmpty ? null : r.note,
      });
    });
    if (ok) _key.currentState?.reload();
  }

  Future<void> _reschedule(_SlotData d, Map<String, dynamic> b) async {
    final newSlot = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => _PickSlotScreen(
          coachId: d.slot['coach_id'] as String, excludeSlot: widget.slotId),
    ));
    if (newSlot == null || !mounted) return;
    final r = await showDialog<ReasonResult>(
      context: context,
      builder: (_) => const ReasonDialog(
          title: 'Move booking', confirm: 'Move booking'),
    );
    if (r == null || !mounted) return;
    final ok = await attempt(context, () async {
      await db.rpc('reschedule_booking', params: {
        'p_booking': b['id'],
        'p_new_slot': newSlot,
        'p_reason': r.reason,
        'p_note': r.note.isEmpty ? null : r.note,
      });
    });
    if (ok) _key.currentState?.reload();
  }

  Future<void> _toggleSlot(_SlotData d) async {
    final cancelled = d.slot['is_cancelled'] as bool;
    if (!cancelled && d.bookings.any((b) => b['status'] == 'BOOKED')) {
      snack(context, 'Cancel or move the bookings first.');
      return;
    }
    final ok = await attempt(context, () async {
      await db
          .from('slots')
          .update({'is_cancelled': !cancelled}).eq('id', widget.slotId);
    });
    if (ok) _key.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: Loader<_SlotData>(
        key: _key,
        load: _load,
        builder: (context, d, reload) {
          final starts = DateTime.parse(d.slot['starts_at'] as String).toLocal();
          final cancelled = d.slot['is_cancelled'] as bool;
          final taken = d.bookings.where((b) => _isTaken(b['status'] as String)).length;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_dayLabel(starts)}  ${showTime(starts)}',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text('Coach ${widget.coachName}'),
                      Text('$taken of ${d.slot['capacity']} places taken'),
                      if (cancelled)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('This session is cancelled',
                              style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => _toggleSlot(d),
                          child: Text(
                              cancelled ? 'Restore session' : 'Cancel session'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!cancelled)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Book a member'),
                    onPressed: () => _addMember(d),
                  ),
                ),
              if (d.bookings.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No bookings yet.'))),
              for (final b in d.bookings)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(d.names[b['member_id']] ?? 'Unknown'),
                  subtitle: Text(_statusLabel(b['status'] as String)),
                  trailing: b['status'] == 'BOOKED'
                      ? PopupMenuButton<String>(
                          onSelected: (v) =>
                              v == 'move' ? _reschedule(d, b) : _cancel(b),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'move', child: Text('Move to another session')),
                            PopupMenuItem(
                                value: 'cancel', child: Text('Cancel booking')),
                          ],
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

String _statusLabel(String s) =>
    s == 'NO_SHOW' ? 'No-show' : s[0] + s.substring(1).toLowerCase();

class _SlotData {
  _SlotData(this.slot, this.bookings, this.names);
  final Map<String, dynamic> slot;
  final List<Map<String, dynamic>> bookings;
  final Map<String, String> names;
}

/// Lists the active members of one coach; pops with the chosen member id.
class _MemberPicker extends StatelessWidget {
  const _MemberPicker(
      {required this.coachId, required this.coachName, required this.excluding});
  final String coachId;
  final String coachName;
  final Set<String> excluding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Members of $coachName')),
      body: Loader<List<Map<String, dynamic>>>(
        load: () async {
          final mp = await db
              .from('member_profiles')
              .select('id')
              .eq('primary_coach_id', coachId);
          final ids = [for (final r in mp) r['id'] as String];
          if (ids.isEmpty) return <Map<String, dynamic>>[];
          final pr = await db
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', ids)
              .eq('is_active', true)
              .order('full_name', ascending: true);
          return List<Map<String, dynamic>>.from(pr);
        },
        builder: (context, rows, reload) {
          final list = rows.where((r) => !excluding.contains(r['id'])).toList();
          return ListView(children: [
            if (list.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                      child: Text('No other active members for this coach.'))),
            for (final r in list)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(r['full_name'] as String? ?? ''),
                onTap: () => Navigator.of(context).pop(r['id'] as String),
              ),
          ]);
        },
      ),
    );
  }
}

/// Lists the coach's upcoming sessions; pops with the chosen slot id.
class _PickSlotScreen extends StatelessWidget {
  const _PickSlotScreen({required this.coachId, required this.excludeSlot});
  final String coachId;
  final String excludeSlot;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Move to which session?')),
      body: Loader<List<Map<String, dynamic>>>(
        load: () async {
          final rows = await db
              .from('slots')
              .select('id, starts_at, capacity, bookings(status)')
              .eq('coach_id', coachId)
              .eq('is_cancelled', false)
              .gte('starts_at', DateTime.now().toUtc().toIso8601String())
              .lt('starts_at',
                  DateTime.now().add(const Duration(days: 21)).toUtc().toIso8601String())
              .order('starts_at', ascending: true);
          return List<Map<String, dynamic>>.from(rows);
        },
        builder: (context, rows, reload) {
          final list = rows.where((r) => r['id'] != excludeSlot).toList();
          return ListView(children: [
            if (list.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No upcoming sessions found.'))),
            for (final r in list)
              Builder(builder: (context) {
                final starts = DateTime.parse(r['starts_at'] as String).toLocal();
                final taken = _takenCount(r);
                final cap = r['capacity'] as int;
                return ListTile(
                  title: Text('${_dayLabel(starts)}  ${showTime(starts)}'),
                  trailing: Text(taken >= cap ? 'Full' : '$taken/$cap'),
                  enabled: taken < cap,
                  onTap: () => Navigator.of(context).pop(r['id'] as String),
                );
              }),
          ]);
        },
      ),
    );
  }
}
