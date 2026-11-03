import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/app_session.dart';

/// Bottom bar for the Member app.
class MemberShell extends StatelessWidget {
  const MemberShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) =>
            shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: 'Book'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.sports_gymnastics), label: 'Workouts'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }
}

/// Stand-in for member screens that are built in later steps.
class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('Coming next')),
      );
}

class MemberMoreScreen extends StatelessWidget {
  const MemberMoreScreen({super.key, required this.session});
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(session.fullName),
            subtitle: const Text('Member'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.fitness_center),
            title: const Text('Equipment'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/member/more/equipment'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Change password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/member/more/password'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: session.signOut,
          ),
        ],
      ),
    );
  }
}
