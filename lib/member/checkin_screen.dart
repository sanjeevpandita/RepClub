import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/common.dart';

final _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final _paste = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _success = false;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _ScannerPage()));
    if (code != null) await _checkIn(code);
  }

  Future<void> _checkIn(String raw) async {
    final token = _uuid.firstMatch(raw)?.group(0);
    if (token == null) {
      setState(() {
        _success = false;
        _message = 'That is not a RepClub QR code.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // The gym door QR first; if the code is not the gym's, it may be a coach's.
      dynamic r;
      try {
        r = await db.rpc('gym_check_in', params: {'p_token': token});
      } on PostgrestException catch (e) {
        if (e.message != 'This QR code is not valid') rethrow;
        r = await db.rpc('qr_check_in', params: {'p_qr_token': token});
      }
      final left = (r is Map ? r['credits_left'] : null);
      setState(() {
        _success = true;
        _message = (r is Map && r['walk_in'] == true)
            ? 'Welcome! Your gym visit is recorded. No credit used.'
            : left == null
            ? 'You are checked in. Enjoy your session!'
            : 'You are checked in. Credits left: $left';
      });
    } on PostgrestException catch (e) {
      setState(() {
        _success = false;
        _message = e.message;
      });
    } catch (_) {
      setState(() {
        _success = false;
        _message = 'Something went wrong. Try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Check in')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 24),
          Icon(Icons.qr_code_scanner,
              size: 96, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Scan the QR code at the gym door, or your coach\'s QR code, when you arrive.',
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
              'Check-in opens 30 minutes before your booked session or gym hour and closes when it ends.',
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.camera_alt),
            label: const Text('Scan QR code'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
          ),
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_message != null) ...[
            const SizedBox(height: 24),
            Card(
              color: (_success ? theme.colorScheme.primary : theme.colorScheme.error)
                  .withValues(alpha: 0.15),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Icon(_success ? Icons.check_circle : Icons.error_outline,
                      color: _success
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_message!)),
                ]),
              ),
            ),
          ],
          if (kDebugMode) ...[
            const SizedBox(height: 40),
            const Divider(),
            Text('Testing only (hidden in the real app)',
                style: theme.textTheme.labelSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _paste,
              decoration: const InputDecoration(
                  labelText: 'Paste coach QR code text',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _checkIn(_paste.text),
              child: const Text('Check in with pasted code'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan coach QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null) {
              _done = true;
              Navigator.of(context).pop(v);
              return;
            }
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
    );
  }
}
