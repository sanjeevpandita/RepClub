import 'package:flutter/material.dart';

import '../auth/app_session.dart';

/// Empty screen for parts of the app not built yet.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text('$title - coming soon')),
    );
  }
}

/// Shown to coaches and members until their apps are built.
class RolePlaceholder extends StatelessWidget {
  const RolePlaceholder(
      {super.key, required this.session, required this.message});
  final AppSession session;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RepClub')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Hi ${session.fullName}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: session.signOut, child: const Text('Sign out')),
          ],
        ),
      ),
    );
  }
}
