import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../shared/common.dart';

/// The QR code for the gym door. Gym members scan it inside their booked hour.
class GymQrScreen extends StatelessWidget {
  const GymQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gym door QR')),
      body: Loader<String>(
        load: () async =>
            (await db.from('gym_qr').select('token').single())['token']
                as String,
        builder: (context, token, reload) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: token, size: 260),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Print this and put it at the door. Members with a Monthly Pass '
              'scan it to check in, but only during the hour they booked.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: token));
                if (context.mounted) snack(context, 'Code copied');
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy code (for testing)'),
            ),
            const Divider(height: 32),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Make a new QR code?'),
                    content: const Text(
                        'The printed code stops working. Use this only if the code has leaked.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Keep')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Make new')),
                    ],
                  ),
                );
                if (yes != true || !context.mounted) return;
                final ok = await attempt(
                    context, () => db.rpc('admin_regenerate_gym_qr'));
                if (ok) reload();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Make a new code'),
            ),
          ],
        ),
      ),
    );
  }
}
