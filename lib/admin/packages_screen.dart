import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient get _db => Supabase.instance.client;

class PackageType {
  PackageType(Map<String, dynamic> r)
      : id = r['id'] as String,
        name = r['name'] as String,
        credits = r['credits'] as int,
        priceEur = (r['price_eur'] as num).toDouble(),
        validityDays = r['validity_days'] as int,
        isActive = r['is_active'] as bool,
        isPass = r['kind'] == 'PASS';

  final bool isPass;
  final String id;
  final String name;
  final int credits;
  final double priceEur;
  final int validityDays;
  final bool isActive;
}

String _eur(double v) =>
    '€${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';

class PackagesScreen extends StatefulWidget {
  const PackagesScreen({super.key});

  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  List<PackageType>? _packages;
  Map<String, int> _counts = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final pk = await _db.from('package_types').select().order('credits');
      final mp = await _db
          .from('member_packages')
          .select('package_type_id')
          .inFilter('status', ['ACTIVE', 'QUEUED']);
      final counts = <String, int>{};
      for (final r in mp) {
        final id = r['package_type_id'] as String;
        counts[id] = (counts[id] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _packages = [for (final r in pk) PackageType(r)];
        _counts = counts;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load packages. Pull down to retry.');
    }
  }

  Future<void> _edit([PackageType? p]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PackageFormScreen(existing: p)),
    );
    if (saved == true) _load();
  }

  Future<void> _toggleActive(PackageType p) async {
    try {
      await _db
          .from('package_types')
          .update({'is_active': !p.isActive}).eq('id', p.id);
      _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final list = _packages;
    return Scaffold(
      appBar: AppBar(title: const Text('Packages')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add package'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: list == null
            ? ListView(children: [
                const SizedBox(height: 120),
                Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Text(_error!),
                ),
              ])
            : ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [for (final p in list) _card(p)],
              ),
      ),
    );
  }

  Widget _card(PackageType p) {
    final n = _counts[p.id] ?? 0;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Opacity(
        opacity: p.isActive ? 1 : 0.6,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(p.name, style: theme.textTheme.titleLarge)),
                if (!p.isActive)
                  const Chip(
                      label: Text('Inactive'), visualDensity: VisualDensity.compact),
              ]),
              const SizedBox(height: 4),
              Text(
                  '${p.isPass ? 'Monthly Pass, unlimited gym' : '${p.credits} credits'}  ·  ${_eur(p.priceEur)}  ·  ${p.validityDays} days'),
              const SizedBox(height: 8),
              Row(children: [
                TextButton.icon(
                  onPressed: n == 0
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => PackageMembersScreen(package: p))),
                  icon: const Icon(Icons.people_outline),
                  label: Text('$n member${n == 1 ? '' : 's'}'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: p.isActive ? 'Deactivate' : 'Activate',
                  icon: Icon(p.isActive
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () => _toggleActive(p),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _edit(p),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class PackageFormScreen extends StatefulWidget {
  const PackageFormScreen({super.key, this.existing});
  final PackageType? existing;

  @override
  State<PackageFormScreen> createState() => _PackageFormScreenState();
}

class _PackageFormScreenState extends State<PackageFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _credits =
      TextEditingController(text: widget.existing?.credits.toString());
  late final _price = TextEditingController(
      text: widget.existing?.priceEur
          .toString()
          .replaceAll(RegExp(r'\.0$'), ''));
  late final _days =
      TextEditingController(text: widget.existing?.validityDays.toString());
  late bool _active = widget.existing?.isActive ?? true;
  late bool _pass = widget.existing?.isPass ?? false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _credits.dispose();
    _price.dispose();
    _days.dispose();
    super.dispose();
  }

  String? _positiveInt(String? v) {
    final n = int.tryParse((v ?? '').trim());
    return n == null || n <= 0 ? 'Enter a whole number above 0' : null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final data = {
      'name': _name.text.trim(),
      'kind': _pass ? 'PASS' : 'CREDITS',
      'credits': _pass ? 0 : int.parse(_credits.text.trim()),
      'price_eur': double.parse(_price.text.trim().replaceAll(',', '.')),
      'validity_days': int.parse(_days.text.trim()),
      'is_active': _active,
    };
    try {
      if (widget.existing == null) {
        await _db.from('package_types').insert(data);
      } else {
        await _db.from('package_types').update(data).eq('id', widget.existing!.id);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null ? 'New package' : 'Edit package')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Monthly Pass (gym access)'),
              subtitle: const Text(
                  'Unlimited gym visits, no credits. Member books a gym hour and scans the door QR'),
              value: _pass,
              onChanged: widget.existing == null
                  ? (v) => setState(() => _pass = v)
                  : null,
            ),
            if (!_pass) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _credits,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Attendance-day credits',
                    border: OutlineInputBorder()),
                validator: _positiveInt,
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Price (EUR)',
                  prefixText: '€ ',
                  helperText: 'For information only - payment is taken offline',
                  border: OutlineInputBorder()),
              validator: (v) {
                final n = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                return n == null || n < 0 ? 'Enter a price (0 or more)' : null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _days,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Valid for (days)', border: OutlineInputBorder()),
              validator: _positiveInt,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Active'),
              subtitle: const Text('Inactive packages cannot be sold to new members'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: 16),
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
        ),
      ),
    );
  }
}

class PackageMembersScreen extends StatefulWidget {
  const PackageMembersScreen({super.key, required this.package});
  final PackageType package;

  @override
  State<PackageMembersScreen> createState() => _PackageMembersScreenState();
}

class _PackageMembersScreenState extends State<PackageMembersScreen> {
  List<({String name, String status, String expiry})>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mp = await _db
          .from('member_packages')
          .select('member_id, status, expiry_date')
          .eq('package_type_id', widget.package.id)
          .inFilter('status', ['ACTIVE', 'QUEUED']);
      final ids = [for (final r in mp) r['member_id'] as String];
      final names = <String, String>{};
      if (ids.isNotEmpty) {
        final pr =
            await _db.from('profiles').select('id, full_name').inFilter('id', ids);
        for (final r in pr) {
          names[r['id'] as String] = r['full_name'] as String? ?? '';
        }
      }
      final rows = [
        for (final r in mp)
          (
            name: names[r['member_id']] ?? 'Unknown',
            status: r['status'] as String,
            expiry: r['expiry_date'] as String,
          )
      ]..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load members.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.package.name} members')),
      body: rows == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!))
          : ListView(children: [
              for (final r in rows)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(r.name),
                  subtitle: Text('Expires ${r.expiry}'),
                  trailing: Text(r.status == 'ACTIVE' ? 'Active' : 'Queued'),
                ),
            ]),
    );
  }
}
