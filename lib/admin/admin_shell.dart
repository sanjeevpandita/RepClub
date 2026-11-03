import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/app_session.dart';

/// Bottom bar for the main Admin areas; the rest live under "More".
class AdminShell extends StatelessWidget {
  const AdminShell({super.key, required this.shell});
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
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: 'Calendar'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'Members'),
          NavigationDestination(
              icon: Icon(Icons.sports_outlined),
              selectedIcon: Icon(Icons.sports),
              label: 'Coaches'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }
}

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key, required this.session});
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
            subtitle: const Text('Admin'),
          ),
          const Divider(),
          _item(context, Icons.card_membership, 'Packages', 'packages'),
          _item(context, Icons.fitness_center, 'Equipment', 'equipment'),
          _item(context, Icons.sports_gymnastics, 'Workouts (muscle groups)', 'workouts'),
          _item(context, Icons.qr_code_2, 'Gym door QR', 'gymqr'),
          _item(context, Icons.assessment_outlined, 'Reports', 'reports'),
          _item(context, Icons.history, 'Audit log', 'audit'),
          _item(context, Icons.settings_outlined, 'Settings', 'settings'),
          _item(context, Icons.lock_outline, 'Change password', 'password'),
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

  Widget _item(
          BuildContext context, IconData icon, String label, String path) =>
      ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/admin/more/$path'),
      );
}
