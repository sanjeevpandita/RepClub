import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/common.dart';

final _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');

enum CheckInKind { coach, gym }

/// Home card: "Check in for" with a Coach session button (members with a coach)
/// and a Gym button (everyone who can book gym time: a coach or a Monthly Pass).
class CheckInCard extends StatelessWidget {
  const CheckInCard({super.key, required this.hasCoach, required this.reload});
  final bool hasCoach;
  final Future<void> Function() reload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Future<void> go(CheckInKind kind) async {
      if (await checkIn(context, kind)) await reload();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.qr_code_scanner, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Check in for', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 4),
            Text(
                'Opens 30 minutes before your booking and closes when it ends.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              if (hasCoach) ...[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => go(CheckInKind.coach),
                    icon: const Icon(Icons.person),
                    label: const Text('Coach session'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => go(CheckInKind.gym),
                  icon: const Icon(Icons.fitness_center),
                  label: const Text('Gym'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Opens the scanner, checks in for the chosen kind and shows the result.
/// Returns true when the check-in worked.
Future<bool> checkIn(BuildContext context, CheckInKind kind) async {
  final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _ScannerPage(kind: kind)));
  if (raw == null || !context.mounted) return false;

  final token = _uuid.firstMatch(raw)?.group(0);
  String message;
  var ok = false;
  if (token == null) {
    message = 'That is not a RepClub QR code.';
  } else {
    try {
      final r = kind == CheckInKind.gym
          ? await db.rpc('gym_check_in', params: {'p_token': token})
          : await db.rpc('qr_check_in', params: {'p_qr_token': token});
      final left = r is Map ? r['credits_left'] : null;
      ok = true;
      message = kind == CheckInKind.gym
          ? 'You are checked in at the gym. Enjoy your workout!'
          : left == null
              ? 'You are checked in. Enjoy your session!'
              : 'You are checked in. Credits left: $left';
    } on PostgrestException catch (e) {
      message = e.message;
      if (e.message == 'This QR code is not valid') {
        message = kind == CheckInKind.gym
            ? 'This is not the gym door QR code. For a coach session, tap "Coach session" instead.'
            : 'This is not your coach\'s QR code. For gym time, tap "Gym" instead.';
      }
    } catch (_) {
      message = 'Something went wrong. Try again.';
    }
  }
  if (!context.mounted) return ok;

  final theme = Theme.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(ok ? Icons.check_circle : Icons.error_outline,
          size: 48,
          color: ok ? theme.colorScheme.primary : theme.colorScheme.error),
      title: Text(ok ? 'Checked in' : 'Could not check in'),
      content: Text(message, textAlign: TextAlign.center),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
  return ok;
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage({required this.kind});
  final CheckInKind kind;

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final _paste = TextEditingController();
  bool _done = false;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _finish(String value) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final gym = widget.kind == CheckInKind.gym;
    return Scaffold(
      appBar: AppBar(title: Text(gym ? 'Scan gym door QR' : 'Scan coach QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                for (final b in capture.barcodes) {
                  final v = b.rawValue;
                  if (v != null) return _finish(v);
                }
              },
              errorBuilder: (context, error) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'The camera could not start. Allow camera access for RepClub in your phone settings.',
                      textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
          // Emulator testing only (the emulator has no real camera). Hidden in the real app.
          if (kDebugMode)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _paste,
                    decoration: const InputDecoration(
                        labelText: 'Testing: paste QR code text',
                        isDense: true,
                        border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: () => _finish(_paste.text),
                    child: const Text('Use')),
              ]),
            ),
        ],
      ),
    );
  }
}
