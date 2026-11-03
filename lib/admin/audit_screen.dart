import 'package:flutter/material.dart';

import '../shared/common.dart';

const _entityLabels = {
  'profiles': 'Profile',
  'member_profiles': 'Member details',
  'coach_profiles': 'Coach',
  'package_types': 'Package',
  'member_packages': 'Member package',
  'bookings': 'Booking',
  'attendance': 'Attendance',
  'equipment': 'Equipment',
};

const _keyActionTitles = {
  'USER_CREATED': 'Login created',
  'CREDIT_ADJUSTMENT': 'Credits adjusted',
  'MANUAL_ATTENDANCE': 'Attendance entered manually',
  'NO_SHOW_WAIVED': 'No-show waived',
  'CANCEL_INSIDE_LOCK': 'Booking cancelled inside the lock window',
  'RESCHEDULE_INSIDE_LOCK': 'Booking moved inside the lock window',
};

// Fields that add nothing when shown in a change.
const _hiddenFields = {'id', 'created_at', 'created_by', 'role'};

String _title(Map<String, dynamic> r) {
  final action = r['action'] as String;
  if (_keyActionTitles.containsKey(action)) return _keyActionTitles[action]!;
  final what = _entityLabels[r['entity']] ?? (r['entity'] as String);
  return switch (action) {
    'INSERT' => '$what created',
    'UPDATE' => '$what edited',
    'DELETE' => '$what removed',
    _ => action,
  };
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  static const _page = 100;

  DateTimeRange _range = () {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    return DateTimeRange(
        start: today.subtract(const Duration(days: 6)), end: today);
  }();
  bool _keyOnly = true;
  final List<Map<String, dynamic>> _rows = [];
  final Map<String, String> _names = {};
  bool _loading = true;
  bool _more = false;
  String? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _gen++;
      _rows.clear();
      _more = false;
    }
    final gen = _gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var q = db
          .from('audit_log')
          .select()
          .gte('at', _range.start.toUtc().toIso8601String())
          .lt(
              'at',
              DateTime(_range.end.year, _range.end.month, _range.end.day + 1)
                  .toUtc()
                  .toIso8601String());
      if (_keyOnly) q = q.not('action', 'in', '(INSERT,UPDATE,DELETE)');
      final rows = await q
          .order('at', ascending: false)
          .order('id', ascending: false)
          .range(_rows.length, _rows.length + _page - 1);

      final need = <String>{};
      for (final r in rows) {
        final actor = r['actor_id'] as String?;
        if (actor != null) need.add(actor);
        for (final d in [r['new_data'], r['old_data']]) {
          final m = (d as Map?)?['member_id'];
          if (m is String) need.add(m);
        }
        if (const {'profiles', 'member_profiles', 'coach_profiles'}
            .contains(r['entity'])) {
          final id = r['entity_id'] as String?;
          if (id != null) need.add(id);
        }
      }
      need.removeAll(_names.keys);
      final fresh = need.isEmpty ? <String, String>{} : await nameMap(need);
      if (!mounted || gen != _gen) return;
      setState(() {
        _names.addAll(fresh);
        _rows.addAll(List<Map<String, dynamic>>.from(rows));
        _more = rows.length == _page;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the audit log.';
      });
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );
    if (r == null) return;
    _range = r;
    _load(reset: true);
  }

  String _who(String? id) => id == null ? 'System' : (_names[id] ?? 'Unknown');

  /// What the entry is about, e.g. the member's name.
  String? _subject(Map<String, dynamic> r) {
    final data = (r['new_data'] ?? r['old_data']) as Map?;
    final member = data?['member_id'];
    if (member is String && _names[member] != null) {
      final extra = data?['package_name'];
      return extra is String ? '${_names[member]} · $extra' : _names[member];
    }
    if (const {'profiles', 'member_profiles', 'coach_profiles'}
        .contains(r['entity'])) {
      final n = _names[r['entity_id']];
      if (n != null) return n;
    }
    final name = data?['full_name'] ?? data?['name'] ?? data?['package_name'];
    return name is String ? name : null;
  }

  void _details(Map<String, dynamic> r) {
    final oldD = (r['old_data'] as Map?)?.cast<String, dynamic>();
    final newD = (r['new_data'] as Map?)?.cast<String, dynamic>();
    final lines = <String>[];
    final keys = {...?oldD?.keys, ...?newD?.keys}
        .where((k) => !_hiddenFields.contains(k))
        .toList()
      ..sort();
    for (final k in keys) {
      final o = oldD?[k], n = newD?[k];
      if (oldD != null && newD != null && o == n) continue; // unchanged
      final label = k.replaceAll('_', ' ');
      if (oldD != null && newD != null) {
        lines.add('$label: ${o ?? '-'}  →  ${n ?? '-'}');
      } else {
        lines.add('$label: ${(n ?? o) ?? '-'}');
      }
    }
    final reason = r['reason_code'] as String?;
    final note = r['note'] as String?;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(_title(r)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${showStamp(r['at'] as String)}  ·  by ${_who(r['actor_id'] as String?)}'),
              if (_subject(r) != null) Text('About: ${_subject(r)}'),
              if (reason != null) Text('Reason: ${reasonLabels[reason] ?? reason}'),
              if (note != null && note.isNotEmpty) Text('Note: $note'),
              if (lines.isNotEmpty) const SizedBox(height: 12),
              for (final l in lines) Text(l),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audit log')),
      body: Column(children: [
        ListTile(
          leading: const Icon(Icons.date_range),
          title: Text('${showDate(_range.start)}  to  ${showDate(_range.end)}'),
          trailing: const Icon(Icons.edit_calendar_outlined),
          onTap: _pickRange,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            ChoiceChip(
              label: const Text('Key actions'),
              selected: _keyOnly,
              onSelected: (_) {
                _keyOnly = true;
                _load(reset: true);
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('All changes'),
              selected: !_keyOnly,
              onSelected: (_) {
                _keyOnly = false;
                _load(reset: true);
              },
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView(children: [
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(_error!))),
              if (_error == null && _rows.isEmpty && !_loading)
                const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: Text('No entries in this period.'))),
              for (final r in _rows) _tile(r),
              if (_loading)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator())),
              if (_more && !_loading)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton(
                      onPressed: () => _load(),
                      child: const Text('Load more')),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _tile(Map<String, dynamic> r) {
    final subject = _subject(r);
    final reason = r['reason_code'] as String?;
    final note = r['note'] as String?;
    return ListTile(
      title: Text(_title(r)),
      subtitle: Text([
        showStamp(r['at'] as String),
        'by ${_who(r['actor_id'] as String?)}',
        ?subject,
        if (reason != null) reasonLabels[reason] ?? reason,
        if (note != null && note.isNotEmpty) note,
      ].join('  ·  ')),
      isThreeLine: true,
      onTap: () => _details(r),
    );
  }
}
