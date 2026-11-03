import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../shared/avatar.dart';
import '../shared/common.dart';
import '../shared/reset_password.dart';
import 'create_user_screen.dart';

// ---------------------------------------------------------------- list

class MemberRow {
  MemberRow({
    required this.id,
    required this.name,
    required this.isActive,
    this.avatarUrl,
    this.coachName,
    this.packageName,
    this.credits,
  });
  final String id;
  final String name;
  final bool isActive;
  final String? avatarUrl;
  final String? coachName;
  final String? packageName;
  final int? credits;
}

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  List<MemberRow>? _all;
  String? _error;
  String _query = '';
  String _filter = 'Active';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pr = await db
          .from('profiles')
          .select('id, full_name, is_active, avatar_url')
          .eq('role', 'MEMBER')
          .order('full_name');
      final mp = await db.from('member_profiles').select('id, primary_coach_id');
      final coaches =
          await db.from('profiles').select('id, full_name').eq('role', 'COACH');
      final pk = await db
          .from('member_packages')
          .select('id, member_id, package_name, kind')
          .eq('status', 'ACTIVE')
          .order('kind', ascending: false); // PASS first, so a credit package wins in the map below
      final bal = await db
          .from('member_package_balances')
          .select('member_package_id, credits_remaining')
          .eq('status', 'ACTIVE');

      final coachName = {
        for (final c in coaches) c['id'] as String: c['full_name'] as String? ?? ''
      };
      final coachOf = {
        for (final m in mp) m['id'] as String: m['primary_coach_id'] as String?
      };
      final credits = {
        for (final b in bal)
          b['member_package_id'] as String: b['credits_remaining'] as int
      };
      final pkgOf = {
        for (final p in pk)
          p['member_id'] as String: (
            name: p['package_name'] as String,
            credits: p['kind'] == 'PASS' ? null : credits[p['id']],
          )
      };

      if (!mounted) return;
      setState(() {
        _all = [
          for (final r in pr)
            MemberRow(
              id: r['id'] as String,
              name: r['full_name'] as String? ?? '',
              isActive: r['is_active'] as bool,
              avatarUrl: r['avatar_url'] as String?,
              coachName: coachName[coachOf[r['id']]],
              packageName: pkgOf[r['id']]?.name,
              credits: pkgOf[r['id']]?.credits,
            )
        ];
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load members. Pull down to retry.');
    }
  }

  Future<void> _open(MemberRow m) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MemberDetailScreen(member: m)));
    _load();
  }

  Future<void> _addInfo() async {
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => const CreateUserScreen(isCoach: false)));
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final shown = all
        ?.where((m) =>
            (_filter == 'All' ||
                (_filter == 'Active') == m.isActive) &&
            m.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Members')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addInfo,
        icon: const Icon(Icons.add),
        label: const Text('Add member'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search by name',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final f in const ['Active', 'Inactive', 'All'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ]),
          ),
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
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        if (shown.isEmpty)
                          const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: Text('No members found.'))),
                        for (final m in shown)
                          Opacity(
                            opacity: m.isActive ? 1 : 0.6,
                            child: ListTile(
                              leading: Avatar(name: m.name, url: m.avatarUrl),
                              title: Text(m.name),
                              subtitle: Text([
                                m.packageName == null
                                    ? 'No active package'
                                    : m.credits == null
                                        ? '${m.packageName}'
                                        : '${m.packageName} · ${m.credits} credits',
                                m.coachName != null
                                    ? 'Coach ${m.coachName}'
                                    : 'No coach (gym only)',
                                if (!m.isActive) 'Inactive',
                              ].join('  ·  ')),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(m),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- detail

class MemberDetailScreen extends StatelessWidget {
  const MemberDetailScreen({super.key, required this.member});
  final MemberRow member;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Text(member.name),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Profile'),
              Tab(text: 'Package'),
              Tab(text: 'Credits'),
              Tab(text: 'Bookings'),
              Tab(text: 'Attendance'),
              Tab(text: 'Weight'),
              Tab(text: 'Equipment'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ProfileTab(memberId: member.id),
            MemberPackageTab(memberId: member.id),
            _CreditsTab(memberId: member.id),
            _BookingsTab(memberId: member.id),
            _AttendanceTab(memberId: member.id),
            _WeightTab(memberId: member.id),
            MemberEquipmentTab(memberId: member.id),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ profile

class _ProfileTab extends StatelessWidget {
  const _ProfileTab({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<({Map<String, dynamic> profile, Map<String, dynamic> member, List<Map<String, dynamic>> coaches})>(
      load: () async {
        final p = await db.from('profiles').select().eq('id', memberId).single();
        final m =
            await db.from('member_profiles').select().eq('id', memberId).single();
        final c = await db
            .from('profiles')
            .select('id, full_name')
            .eq('role', 'COACH')
            .order('full_name');
        return (profile: p, member: m, coaches: List<Map<String, dynamic>>.from(c));
      },
      builder: (context, d, reload) => ListView(
        padding: const EdgeInsets.all(16),
        children: [_ProfileForm(memberId: memberId, data: d)],
      ),
    );
  }
}

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({required this.memberId, required this.data});
  final String memberId;
  final ({Map<String, dynamic> profile, Map<String, dynamic> member, List<Map<String, dynamic>> coaches}) data;

  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  late final _name = TextEditingController(text: widget.data.profile['full_name']);
  late final _mobile = TextEditingController(text: widget.data.profile['mobile']);
  late final _gender = TextEditingController(text: widget.data.member['gender']);
  late final _emergency =
      TextEditingController(text: widget.data.member['emergency_contact']);
  late bool _active = widget.data.profile['is_active'] as bool;
  late String? _coach = widget.data.member['primary_coach_id'] as String?;
  late DateTime? _dob = widget.data.member['date_of_birth'] == null
      ? null
      : DateTime.parse(widget.data.member['date_of_birth'] as String);
  bool _saving = false;
  Uint8List? _photo; // newly picked, uploaded on Save

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    _gender.dispose();
    _emergency.dispose();
    super.dispose();
  }

  String? _n(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _pickDob() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(1990),
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _dob = d);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      snack(context, 'Enter a name');
      return;
    }
    setState(() => _saving = true);
    final ok = await attempt(context, () async {
      await db.from('profiles').update({
        'full_name': _name.text.trim(),
        'mobile': _n(_mobile),
        'is_active': _active,
      }).eq('id', widget.memberId);
      await db.from('member_profiles').update({
        'gender': _n(_gender),
        'emergency_contact': _n(_emergency),
        'date_of_birth': _dob == null ? null : isoDate(_dob!),
        'primary_coach_id': _coach,
      }).eq('id', widget.memberId);
    });
    if (!mounted) return;
    var message = 'Saved';
    if (ok && _photo != null) {
      try {
        await uploadAvatar(widget.memberId, _photo!);
        _photo = null;
      } catch (_) {
        message = 'Saved, but the photo could not be uploaded. Try again.';
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) snack(context, message);
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AvatarPicker(
          name: _name.text,
          url: widget.data.profile['avatar_url'] as String?,
          onPicked: (b) => _photo = b,
        ),
        gap,
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              labelText: 'Full name', border: OutlineInputBorder()),
        ),
        gap,
        TextField(
          controller: _mobile,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
              labelText: 'Mobile', border: OutlineInputBorder()),
        ),
        gap,
        InputDecorator(
          decoration: const InputDecoration(
              labelText: 'Login email (cannot be changed here)',
              border: OutlineInputBorder()),
          child: Text(widget.data.profile['email'] as String? ?? '-'),
        ),
        gap,
        InkWell(
          onTap: _pickDob,
          child: InputDecorator(
            decoration: const InputDecoration(
                labelText: 'Date of birth', border: OutlineInputBorder()),
            child: Text(_dob == null ? 'Not set' : showDate(_dob!)),
          ),
        ),
        gap,
        TextField(
          controller: _gender,
          decoration: const InputDecoration(
              labelText: 'Gender', border: OutlineInputBorder()),
        ),
        gap,
        TextField(
          controller: _emergency,
          decoration: const InputDecoration(
              labelText: 'Emergency contact', border: OutlineInputBorder()),
        ),
        gap,
        DropdownButtonFormField<String?>(
          initialValue: _coach,
          decoration: const InputDecoration(
              labelText: 'Primary coach', border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem(value: null, child: Text('No coach')),
            for (final c in widget.data.coaches)
              DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text(c['full_name'] as String? ?? '')),
          ],
          onChanged: (v) => setState(() => _coach = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Active'),
          subtitle: const Text('Inactive members cannot sign in'),
          value: _active,
          onChanged: (v) => setState(() => _active = v),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
        gap,
        ResetPasswordButton(
            userId: widget.memberId,
            name: widget.data.profile['full_name'] as String? ?? 'this member'),
      ],
    );
  }
}

// ------------------------------------------------------------ package

class MemberPackageTab extends StatelessWidget {
  const MemberPackageTab({super.key, required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<({List<Map<String, dynamic>> packages, Map<String, int> credits})>(
      load: () async {
        final mp = await db
            .from('member_packages')
            .select()
            .eq('member_id', memberId)
            .order('created_at', ascending: false);
        final bal = await db
            .from('member_package_balances')
            .select('member_package_id, credits_remaining')
            .eq('member_id', memberId);
        return (
          packages: List<Map<String, dynamic>>.from(mp),
          credits: {
            for (final b in bal)
              b['member_package_id'] as String: b['credits_remaining'] as int
          },
        );
      },
      builder: (context, d, reload) {
        final currentKinds = {
          for (final p in d.packages)
            if (p['status'] == 'ACTIVE' || p['status'] == 'QUEUED')
              p['kind'] as String
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Assign package'),
              onPressed: () async {
                final done = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => AssignPackageScreen(
                        memberId: memberId, currentKinds: currentKinds),
                  ),
                );
                if (done == true) reload();
              },
            ),
            const SizedBox(height: 8),
            if (d.packages.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No packages yet.'))),
            for (final p in d.packages) _packageCard(context, p, d.credits, reload),
          ],
        );
      },
    );
  }

  Widget _packageCard(BuildContext context, Map<String, dynamic> p,
      Map<String, int> credits, Future<void> Function() reload) {
    final status = p['status'] as String;
    final left = credits[p['id']] ?? 0;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(p['package_name'] as String,
                      style: theme.textTheme.titleMedium)),
              Chip(
                label: Text(status[0] + status.substring(1).toLowerCase()),
                visualDensity: VisualDensity.compact,
                backgroundColor:
                    status == 'ACTIVE' ? theme.colorScheme.primary : null,
                labelStyle:
                    status == 'ACTIVE' ? const TextStyle(color: Colors.black) : null,
              ),
            ]),
            const SizedBox(height: 4),
            Text(p['kind'] == 'PASS'
                ? 'Monthly Pass - unlimited gym visits'
                : '$left of ${p['starting_credits']} credits left'),
            Text(
                '${showIso(p['start_date'] as String)} to ${showIso(p['expiry_date'] as String)}'),
            if ((p['payment_note'] as String?)?.isNotEmpty ?? false)
              Text('Payment: ${p['payment_note']}'),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (status == 'QUEUED' ||
                    status == 'ACTIVE' ||
                    status == 'EXHAUSTED')
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    onPressed: () async {
                      final r = await showDialog<ReasonResult>(
                        context: context,
                        builder: (_) => ReasonDialog(
                          title: status == 'QUEUED'
                              ? 'Remove this package?'
                              : 'Cancel this package? Credits left are removed.',
                          confirm: 'Cancel package',
                        ),
                      );
                      if (r == null || !context.mounted) return;
                      final ok = await attempt(context, () async {
                        await db.rpc('admin_cancel_package', params: {
                          'p_package': p['id'],
                          'p_reason': r.reason,
                          'p_note': r.note.isEmpty ? null : r.note,
                        });
                      });
                      if (ok) reload();
                    },
                    child: const Text('Cancel package'),
                  ),
                if (status == 'QUEUED')
                  TextButton(
                    onPressed: () async {
                      final ok = await attempt(context, () async {
                        await db.rpc('admin_activate_package',
                            params: {'p_member_package': p['id']});
                      });
                      if (ok) reload();
                    },
                    child: const Text('Activate now'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AssignPackageScreen extends StatefulWidget {
  const AssignPackageScreen(
      {super.key, required this.memberId, required this.currentKinds});
  final String memberId;

  /// Kinds ('CREDITS', 'PASS') the member already has active or queued.
  final Set<String> currentKinds;

  @override
  State<AssignPackageScreen> createState() => _AssignPackageScreenState();
}

class _AssignPackageScreenState extends State<AssignPackageScreen> {
  List<Map<String, dynamic>>? _types;
  Map<String, dynamic>? _type;
  DateTime _purchase = DateTime.now();
  DateTime _start = DateTime.now();
  DateTime? _expiry;
  final _credits = TextEditingController();
  final _note = TextEditingController();
  bool _activate = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    db
        .from('package_types')
        .select()
        .eq('is_active', true)
        .order('credits')
        .then((rows) {
      if (mounted) setState(() => _types = List<Map<String, dynamic>>.from(rows));
    });
  }

  @override
  void dispose() {
    _credits.dispose();
    _note.dispose();
    super.dispose();
  }

  void _recalc() {
    final t = _type;
    if (t == null) return;
    _expiry = _start.add(Duration(days: t['validity_days'] as int));
  }

  void _selectType(Map<String, dynamic>? t) {
    setState(() {
      _type = t;
      if (t != null) {
        _credits.text = (t['credits'] as int).toString();
        _activate = !widget.currentKinds.contains(t['kind']);
      }
      _recalc();
    });
  }

  Future<DateTime?> _pick(DateTime initial, {DateTime? first}) => showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: first ?? DateTime(2020),
        lastDate: DateTime(2100),
      );

  Future<void> _save() async {
    final credits =
        _type?['kind'] == 'PASS' ? 0 : int.tryParse(_credits.text.trim());
    if (_type == null || _expiry == null) {
      snack(context, 'Choose a package');
      return;
    }
    if (credits == null || credits < 0) {
      snack(context, 'Enter the starting credits');
      return;
    }
    setState(() => _saving = true);
    final ok = await attempt(context, () async {
      await db.rpc('admin_assign_package', params: {
        'p_member': widget.memberId,
        'p_package_type': _type!['id'],
        'p_purchase_date': isoDate(_purchase),
        'p_start_date': isoDate(_start),
        'p_expiry_date': isoDate(_expiry!),
        'p_starting_credits': credits,
        'p_payment_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'p_activate': _activate,
      });
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
    }
  }

  Widget _dateField(String label, DateTime? value, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: InputDecorator(
          decoration:
              InputDecoration(labelText: label, border: const OutlineInputBorder()),
          child: Text(value == null ? '-' : showDate(value)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(title: const Text('Assign package')),
      body: _types == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<Map<String, dynamic>>(
                  initialValue: _type,
                  decoration: const InputDecoration(
                      labelText: 'Package', border: OutlineInputBorder()),
                  items: [
                    for (final t in _types!)
                      DropdownMenuItem(
                        value: t,
                        child: Text(t['kind'] == 'PASS'
                            ? '${t['name']} (unlimited gym, €${t['price_eur']})'
                            : '${t['name']} (${t['credits']} credits, €${t['price_eur']})'),
                      ),
                  ],
                  onChanged: _selectType,
                ),
                gap,
                _dateField('Purchase date', _purchase, () async {
                  final d = await _pick(_purchase);
                  if (d != null) setState(() => _purchase = d);
                }),
                gap,
                _dateField('Start date', _start, () async {
                  final d = await _pick(_start);
                  if (d != null) {
                    setState(() {
                      _start = d;
                      _recalc();
                    });
                  }
                }),
                gap,
                _dateField('Expiry date', _expiry, () async {
                  final d = await _pick(_expiry ?? _start, first: _start);
                  if (d != null) setState(() => _expiry = d);
                }),
                gap,
                if (_type?['kind'] != 'PASS') ...[
                  TextField(
                    controller: _credits,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Starting credits',
                        border: OutlineInputBorder()),
                  ),
                  gap,
                ],
                TextField(
                  controller: _note,
                  decoration: const InputDecoration(
                      labelText: 'Payment note (optional)',
                      helperText: 'e.g. Paid cash 26/10',
                      border: OutlineInputBorder()),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activate now'),
                  subtitle: const Text(
                      'Off = queued until the current package ends or you activate it'),
                  value: _activate,
                  onChanged: (v) => setState(() => _activate = v),
                ),
                gap,
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Assign package'),
                ),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------ credits

class _CreditsTab extends StatelessWidget {
  const _CreditsTab({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<({List<Map<String, dynamic>> rows, int? balance})>(
      load: () async {
        // Oldest first, so the balance after each change can be added up.
        final all = <Map<String, dynamic>>[];
        for (var from = 0;; from += 1000) {
          final page = await db
              .from('credit_transactions')
              .select()
              .eq('member_id', memberId)
              .order('created_at')
              .order('id')
              .range(from, from + 999);
          all.addAll(page);
          if (page.length < 1000) break;
        }
        final running = <String, int>{}; // balance per package
        final rows = <Map<String, dynamic>>[];
        for (final r in all) {
          final pkg = r['member_package_id'] as String;
          final after = (running[pkg] ?? 0) + (r['delta'] as int);
          running[pkg] = after;
          rows.add({...r, 'balance_after': after});
        }
        final names = await nameMap([
          for (final r in rows)
            if (r['created_by'] != null) r['created_by'] as String
        ]);
        for (final r in rows) {
          r['by'] = r['created_by'] == null
              ? 'System'
              : (names[r['created_by']] ?? 'Unknown');
        }
        final bal = await db
            .from('member_package_balances')
            .select('credits_remaining')
            .eq('member_id', memberId)
            .eq('status', 'ACTIVE')
            .eq('kind', 'CREDITS')
            .maybeSingle();
        return (
          rows: rows.reversed.toList(), // newest first for display
          balance: bal?['credits_remaining'] as int?,
        );
      },
      builder: (context, d, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Credits left (active package)'),
                      Text(d.balance?.toString() ?? '-',
                          style: Theme.of(context).textTheme.headlineMedium),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: d.balance == null
                      ? null
                      : () async {
                          final r = await showDialog<ReasonResult>(
                            context: context,
                            builder: (_) => const ReasonDialog(
                                title: 'Adjust credits',
                                confirm: 'Apply',
                                withDelta: true),
                          );
                          if (r == null || !context.mounted) return;
                          final ok = await attempt(context, () async {
                            await db.rpc('admin_adjust_credits', params: {
                              'p_member': memberId,
                              'p_delta': r.delta,
                              'p_reason': r.reason,
                              'p_note': r.note.isEmpty ? null : r.note,
                            });
                          });
                          if (ok) reload();
                        },
                  child: const Text('Adjust'),
                ),
              ]),
            ),
          ),
          if (d.rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No credit history yet.'))),
          for (final r in d.rows) _row(r),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final delta = r['delta'] as int;
    final void_ = r['is_void'] as bool;
    final reason = r['reason_code'] as String?;
    final note = r['note'] as String?;
    final type = (r['type'] as String).replaceAll('_', ' ').toLowerCase();
    return ListTile(
      dense: true,
      title: Text(
        type[0].toUpperCase() + type.substring(1),
        style: void_
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text([
        showStamp(r['created_at'] as String),
        if (reason != null) reasonLabels[reason] ?? reason,
        if (note != null && note.isNotEmpty) note,
        'By ${r['by']}',
        if (void_) 'reversed',
      ].join('  ·  ')),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            delta > 0 ? '+$delta' : '$delta',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: delta > 0 ? const Color(0xFFAAFF00) : null,
            ),
          ),
          Text('Balance ${r['balance_after']}',
              style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ bookings

class _BookingsTab extends StatelessWidget {
  const _BookingsTab({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final rows = await db
            .from('bookings')
            .select('id, status, booking_date, slots(starts_at)')
            .eq('member_id', memberId)
            .order('booking_date', ascending: false)
            .limit(100);
        return List<Map<String, dynamic>>.from(rows);
      },
      builder: (context, rows, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No bookings yet.'))),
          for (final b in rows) _row(context, b, reload),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> b,
      Future<void> Function() reload) {
    final status = b['status'] as String;
    final starts = b['slots'] == null
        ? null
        : DateTime.parse((b['slots'] as Map)['starts_at'] as String).toLocal();
    final canCancel =
        status == 'BOOKED' && starts != null && starts.isAfter(DateTime.now());
    return ListTile(
      title: Text(
          '${showIso(b['booking_date'] as String)}${starts == null ? '' : '  ${showTime(starts)}'}'),
      subtitle: Text(status[0] + status.substring(1).toLowerCase().replaceAll('_', ' ')),
      trailing: canCancel
          ? TextButton(
              onPressed: () async {
                final r = await showDialog<ReasonResult>(
                  context: context,
                  builder: (_) => const ReasonDialog(
                      title: 'Cancel booking', confirm: 'Cancel booking'),
                );
                if (r == null || !context.mounted) return;
                final ok = await attempt(context, () async {
                  await db.rpc('cancel_booking', params: {
                    'p_booking': b['id'],
                    'p_reason': r.reason,
                    'p_note': r.note.isEmpty ? null : r.note,
                  });
                });
                if (ok) reload();
              },
              child: const Text('Cancel'),
            )
          : null,
    );
  }
}

// ------------------------------------------------------------ attendance

class _AttendanceTab extends StatelessWidget {
  const _AttendanceTab({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final rows = await db
            .from('attendance')
            .select('attendance_date, checked_in_at, method, reason_code, note')
            .eq('member_id', memberId)
            .order('attendance_date', ascending: false)
            .limit(100);
        return List<Map<String, dynamic>>.from(rows);
      },
      builder: (context, rows, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No attendance yet.'))),
          for (final a in rows)
            ListTile(
              leading: Icon(a['method'] == 'QR'
                  ? Icons.qr_code_2
                  : Icons.edit_note),
              title: Text(showIso(a['attendance_date'] as String)),
              subtitle: Text([
                a['method'] == 'QR' ? 'QR check-in' : 'Manual',
                showTime(DateTime.parse(a['checked_in_at'] as String).toLocal()),
                if (a['reason_code'] != null)
                  reasonLabels[a['reason_code']] ?? a['reason_code'] as String,
                if ((a['note'] as String?)?.isNotEmpty ?? false)
                  a['note'] as String,
              ].join('  ·  ')),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ weight

class _WeightTab extends StatelessWidget {
  const _WeightTab({required this.memberId});
  final String memberId;

  @override
  Widget build(BuildContext context) {
    return Loader<List<Map<String, dynamic>>>(
      load: () async {
        final rows = await db
            .from('weight_logs')
            .select('weight_kg, logged_on')
            .eq('member_id', memberId)
            .order('logged_on', ascending: false)
            .limit(100);
        return List<Map<String, dynamic>>.from(rows);
      },
      builder: (context, rows, reload) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No weight entries yet.'))),
          for (final w in rows)
            ListTile(
              dense: true,
              title: Text('${(w['weight_kg'] as num).toStringAsFixed(1)} kg'),
              trailing: Text(showIso(w['logged_on'] as String)),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------- equipment

class MemberEquipmentTab extends StatefulWidget {
  const MemberEquipmentTab({super.key, required this.memberId});
  final String memberId;

  @override
  State<MemberEquipmentTab> createState() => MemberEquipmentTabState();
}

class MemberEquipmentTabState extends State<MemberEquipmentTab> {
  final _loader =
      GlobalKey<LoaderState<({List<Map<String, dynamic>> all, Set<String> assigned})>>();

  @override
  Widget build(BuildContext context) {
    return Loader<({List<Map<String, dynamic>> all, Set<String> assigned})>(
      key: _loader,
      load: () async {
        final all = List<Map<String, dynamic>>.from(await db
            .from('equipment')
            .select('id, machine_number, name')
            .eq('is_active', true)
            .order('machine_number'));
        final mine = await db
            .from('equipment_assignments')
            .select('equipment_id')
            .eq('member_id', widget.memberId);
        return (
          all: all,
          assigned: {for (final r in mine) r['equipment_id'] as String},
        );
      },
      builder: (context, data, reload) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
                'Tick the machines this member should see by default in their app.'),
          ),
          if (data.all.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No equipment yet.'))),
          for (final e in data.all)
            CheckboxListTile(
              value: data.assigned.contains(e['id']),
              title: Text(e['name'] as String),
              subtitle: Text('Machine ${e['machine_number']}'),
              onChanged: (v) async {
                final ok = await attempt(context, () async {
                  if (v == true) {
                    await db.from('equipment_assignments').insert({
                      'member_id': widget.memberId,
                      'equipment_id': e['id'],
                    });
                  } else {
                    await db
                        .from('equipment_assignments')
                        .delete()
                        .eq('member_id', widget.memberId)
                        .eq('equipment_id', e['id']);
                  }
                });
                if (ok) await reload();
              },
            ),
        ],
      ),
    );
  }
}
