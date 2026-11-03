import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../shared/common.dart';

/// The coach's own check-in QR, shown large for members to scan.
class CoachQrScreen extends StatelessWidget {
  const CoachQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My check-in QR')),
      body: Loader<String?>(
        load: () async {
          final r = await db
              .from('coach_profiles')
              .select('qr_token')
              .eq('id', db.auth.currentUser!.id)
              .maybeSingle();
          return r?['qr_token'] as String?;
        },
        builder: (context, token, reload) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Members scan this code with the RepClub app to check in.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (token == null)
              const Center(child: Text('No QR code found for your account.'))
            else
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: QrImageView(data: token, size: 280),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
