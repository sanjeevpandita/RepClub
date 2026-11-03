import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient get db => Supabase.instance.client;

const reasonLabels = {
  'ILLNESS': 'Illness',
  'INJURY': 'Injury',
  'GYM_CLOSURE': 'Gym closure',
  'COACH_UNAVAILABLE': 'Coach unavailable',
  'GOODWILL': 'Goodwill',
  'OTHER': 'Other (note required)',
};

String two(int n) => n.toString().padLeft(2, '0');
String isoDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String showDate(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
String showIso(String iso) => showDate(DateTime.parse(iso));
String showTime(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String showStamp(String ts) {
  final d = DateTime.parse(ts).toLocal();
  return '${showDate(d)} ${showTime(d)}';
}

void snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// Runs a database action; shows the server's message if it is refused.
Future<bool> attempt(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } on PostgrestException catch (e) {
    if (context.mounted) snack(context, e.message);
  } catch (_) {
    if (context.mounted) snack(context, 'Something went wrong. Try again.');
  }
  return false;
}

/// Loads data once, shows a spinner/error, and supports pull-to-refresh.
/// The builder must return a scrollable (ListView).
class Loader<T> extends StatefulWidget {
  const Loader({super.key, required this.load, required this.builder});
  final Future<T> Function() load;
  final Widget Function(BuildContext, T data, Future<void> Function() reload)
      builder;

  @override
  State<Loader<T>> createState() => LoaderState<T>();
}

class LoaderState<T> extends State<Loader<T>> {
  T? _data;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final d = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = d;
        _loaded = true;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load. Pull down to retry.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: reload,
      child: _loaded
          ? widget.builder(context, _data as T, reload)
          : ListView(children: [
              const SizedBox(height: 120),
              Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Text(_error!)),
            ]),
    );
  }
}

// ------------------------------------------------------------ reason dialog

typedef ReasonResult = ({int? delta, String reason, String note});

class ReasonDialog extends StatefulWidget {
  const ReasonDialog(
      {super.key, required this.title, required this.confirm, this.withDelta = false});
  final String title;
  final String confirm;
  final bool withDelta;

  @override
  State<ReasonDialog> createState() => ReasonDialogState();
}

class ReasonDialogState extends State<ReasonDialog> {
  final _delta = TextEditingController();
  final _note = TextEditingController();
  String _reason = 'GOODWILL';
  String? _error;

  @override
  void dispose() {
    _delta.dispose();
    _note.dispose();
    super.dispose();
  }

  void _ok() {
    int? delta;
    if (widget.withDelta) {
      delta = int.tryParse(_delta.text.trim().replaceFirst('+', ''));
      if (delta == null || delta == 0) {
        setState(() => _error = 'Enter a number such as 2 or -1');
        return;
      }
    }
    if (_reason == 'OTHER' && _note.text.trim().isEmpty) {
      setState(() => _error = 'A note is needed when the reason is Other');
      return;
    }
    Navigator.of(context)
        .pop((delta: delta, reason: _reason, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.withDelta) ...[
              TextField(
                controller: _delta,
                keyboardType:
                    const TextInputType.numberWithOptions(signed: true),
                decoration: const InputDecoration(
                    labelText: 'Credits to add (or minus to remove)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<String>(
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Reason', border: OutlineInputBorder()),
              items: [
                for (final e in reasonLabels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _reason = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                  labelText: 'Note', border: OutlineInputBorder()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _ok,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}


Future<Map<String, String>> nameMap(Iterable<String> ids) async {
  final list = ids.toSet().toList();
  final out = <String, String>{};
  for (var i = 0; i < list.length; i += 100) {
    final chunk = list.sublist(i, min(i + 100, list.length));
    final pr =
        await db.from('profiles').select('id, full_name').inFilter('id', chunk);
    for (final p in pr) {
      out[p['id'] as String] = p['full_name'] as String? ?? '';
    }
  }
  return out;
}

/// A member with this many credits left (or fewer) counts as running low.
const lowCreditLimit = 3;
