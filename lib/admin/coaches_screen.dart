import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/avatar.dart';
import '../shared/reset_password.dart';
import 'create_user_screen.dart';
import 'schedule_screen.dart';

SupabaseClient get _db => Supabase.instance.client;

class Coach {
  Coach(Map<String, dynamic> r, this.memberCount)
    : id = r['id'] as String,
      name = (r['full_name'] as String?) ?? '',
      mobile = r['mobile'] as String?,
      email = r['email'] as String?,
      avatarUrl = r['avatar_url'] as String?,
      isActive = r['is_active'] as bool;

  final String id;
  final String name;
  final String? mobile;
  final String? email;
  final String? avatarUrl;
  final bool isActive;
  final int memberCount;
}

class CoachesScreen extends StatefulWidget {
  const CoachesScreen({super.key});

  @override
  State<CoachesScreen> createState() => _CoachesScreenState();
}

class _CoachesScreenState extends State<CoachesScreen> {
  List<Coach>? _coaches;
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
      final pr = await _db
          .from('profiles')
          .select('id, full_name, mobile, email, is_active, avatar_url')
          .eq('role', 'COACH')
          .order('full_name', ascending: true);
      final mp = await _db.from('member_profiles').select('primary_coach_id');
      final counts = <String, int>{};
      for (final r in mp) {
        final c = r['primary_coach_id'] as String?;
        if (c != null) counts[c] = (counts[c] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _coaches = [for (final r in pr) Coach(r, counts[r['id']] ?? 0)];
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load coaches. Pull down to retry.');
    }
  }

  Future<void> _open(Coach c) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CoachDetailScreen(coach: c)),
    );
    if (changed == true) _load();
  }

  Future<void> _addInfo() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateUserScreen(isCoach: true)),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _coaches
        ?.where(
          (c) =>
              (_filter == 'All' || (_filter == 'Active') == c.isActive) &&
              c.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Coaches')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addInfo,
        icon: const Icon(Icons.add),
        label: const Text('Add coach'),
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
            child: Row(
              children: [
                for (final f in const ['Active', 'Inactive', 'All'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: list == null
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: _error == null
                              ? const CircularProgressIndicator()
                              : Text(_error!),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        if (list.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('No coaches found.')),
                          ),
                        for (final c in list)
                          Opacity(
                            opacity: c.isActive ? 1 : 0.6,
                            child: ListTile(
                              leading: Avatar(name: c.name, url: c.avatarUrl),
                              title: Text(c.name),
                              subtitle: Text(
                                '${c.memberCount} member${c.memberCount == 1 ? '' : 's'}'
                                '${c.isActive ? '' : '  ·  Inactive'}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(c),
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

class CoachDetailScreen extends StatefulWidget {
  const CoachDetailScreen({super.key, required this.coach});
  final Coach coach;

  @override
  State<CoachDetailScreen> createState() => _CoachDetailScreenState();
}

class _CoachDetailScreenState extends State<CoachDetailScreen> {
  late final _name = TextEditingController(text: widget.coach.name);
  late final _mobile = TextEditingController(text: widget.coach.mobile);
  late bool _active = widget.coach.isActive;
  bool _saving = false;
  bool _changed = false;
  Uint8List? _photo; // newly picked, uploaded on Save
  bool _showQr = false;
  String? _qrToken;
  List<String>? _members;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _loadMembers() async {
    try {
      final mp = await _db
          .from('member_profiles')
          .select('id')
          .eq('primary_coach_id', widget.coach.id);
      final ids = [for (final r in mp) r['id'] as String];
      var names = <String>[];
      if (ids.isNotEmpty) {
        final pr = await _db
            .from('profiles')
            .select('full_name')
            .inFilter('id', ids)
            .order('full_name');
        names = [for (final r in pr) (r['full_name'] as String?) ?? ''];
      }
      if (mounted) setState(() => _members = names);
    } catch (_) {
      if (mounted) setState(() => _members = []);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Enter a name');
      return;
    }
    setState(() => _saving = true);
    try {
      await _db
          .from('profiles')
          .update({
            'full_name': _name.text.trim(),
            'mobile': _mobile.text.trim().isEmpty ? null : _mobile.text.trim(),
            'is_active': _active,
          })
          .eq('id', widget.coach.id);
      _changed = true;
      if (_photo != null) {
        try {
          await uploadAvatar(widget.coach.id, _photo!);
        } catch (_) {
          if (!mounted) return;
          setState(() => _saving = false);
          _snack('Saved, but the photo could not be uploaded. Try again.');
          return;
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(e.message);
    }
  }

  Future<void> _toggleQr() async {
    if (_showQr) {
      setState(() => _showQr = false);
      return;
    }
    try {
      final row = await _db
          .from('coach_profiles')
          .select('qr_token')
          .eq('id', widget.coach.id)
          .single();
      setState(() {
        _qrToken = row['qr_token'] as String;
        _showQr = true;
      });
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.coach.name)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AvatarPicker(
              name: widget.coach.name,
              url: widget.coach.avatarUrl,
              onPicked: (b) => _photo = b,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _mobile,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Login email (cannot be changed here)',
                border: OutlineInputBorder(),
              ),
              child: Text(widget.coach.email ?? '-'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              subtitle: const Text('Inactive coaches cannot sign in'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const SizedBox(height: 12),
            ResetPasswordButton(
              userId: widget.coach.id,
              name: widget.coach.name,
            ),
            const Divider(height: 40),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WeeklyScheduleScreen(
                    coachId: widget.coach.id,
                    coachName: widget.coach.name,
                  ),
                ),
              ),
              icon: const Icon(Icons.calendar_view_week),
              label: const Text('Weekly hours'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _toggleQr,
              icon: const Icon(Icons.qr_code_2),
              label: Text(_showQr ? 'Hide check-in QR' : 'Show check-in QR'),
            ),
            if (_showQr && _qrToken != null) ...[
              const SizedBox(height: 16),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: _qrToken!, size: 240),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _qrToken!));
                  _snack('Code copied');
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy code (for testing)'),
              ),
              Text(
                'Members scan this to check in. Keep it private to the gym.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const Divider(height: 40),
            Text('Members', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_members == null)
              const Center(child: CircularProgressIndicator())
            else if (_members!.isEmpty)
              const Text('No members assigned yet.')
            else
              for (final n in _members!)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(n),
                ),
          ],
        ),
      ),
    );
  }
}
