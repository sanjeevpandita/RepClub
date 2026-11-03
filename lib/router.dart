import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin/admin_shell.dart';
import 'admin/audit_screen.dart';
import 'admin/calendar_screen.dart';
import 'admin/coaches_screen.dart';
import 'admin/equipment_screen.dart';
import 'admin/gym_qr_screen.dart';
import 'admin/members_screen.dart';
import 'admin/packages_screen.dart';
import 'admin/reports_screen.dart';
import 'admin/settings_screen.dart';
import 'admin/workout_library_screen.dart';
import 'admin/dashboard_screen.dart';
import 'auth/app_session.dart';
import 'coach/coach_shell.dart';
import 'coach/members_screen.dart';
import 'coach/qr_screen.dart';
import 'coach/schedule_screen.dart';
import 'coach/today_screen.dart';
import 'member/gym_book_screen.dart';
import 'member/equipment_screen.dart';
import 'member/history_screen.dart';
import 'member/home_screen.dart';
import 'member/member_shell.dart';
import 'member/workouts_screen.dart';
import 'screens/login_screen.dart';
import 'shared/change_password_screen.dart';

GoRouter buildRouter(AppSession session) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: session,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      switch (session.status) {
        case SessionStatus.loading:
          return loc == '/' ? null : '/';
        case SessionStatus.signedOut:
          return loc == '/login' ? null : '/login';
        case SessionStatus.signedIn:
          final home = switch (session.role!) {
            UserRole.admin => '/admin/dashboard',
            UserRole.coach => '/coach',
            UserRole.member => '/member',
          };
          // Keep each role inside its own area.
          if (loc == '/' || loc == '/login') return home;
          if (session.role == UserRole.admin) {
            return loc.startsWith('/admin') ? null : home;
          }
          return loc.startsWith(home) ? null : home;
      }
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => ListenableBuilder(
          listenable: session,
          builder: (_, _) => Scaffold(
            body: Center(
              child: session.loadError == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(session.loadError!,
                              textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: session.retry,
                              child: const Text('Retry')),
                          TextButton(
                              onPressed: session.signOut,
                              child: const Text('Sign out')),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
      GoRoute(path: '/login', builder: (_, _) => LoginScreen(session: session)),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => CoachShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/coach', builder: (_, _) => const CoachTodayScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/coach/schedule',
                builder: (_, _) => const CoachScheduleScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/coach/members',
                builder: (_, _) => const CoachMembersScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/coach/qr', builder: (_, _) => const CoachQrScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/coach/more',
                builder: (_, _) => CoachMoreScreen(session: session),
                routes: [
                  GoRoute(
                    path: 'password',
                    builder: (_, _) => const ChangePasswordScreen(),
                  ),
                ]),
          ]),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => MemberShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/member',
              builder: (_, _) => HomeScreen(name: session.fullName),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/member/book',
                builder: (_, _) => const BookHub()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/member/history',
                builder: (_, _) => const HistoryScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/member/workouts',
                builder: (_, _) => const MemberWorkoutsScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
                path: '/member/more',
                builder: (_, _) => MemberMoreScreen(session: session),
                routes: [
                  GoRoute(
                    path: 'equipment',
                    builder: (_, _) => const MemberEquipmentScreen(),
                  ),
                  GoRoute(
                    path: 'password',
                    builder: (_, _) => const ChangePasswordScreen(),
                  ),
                ]),
          ]),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AdminShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/dashboard', builder: (_, _) => const DashboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/calendar', builder: (_, _) => const CalendarScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/members', builder: (_, _) => const MembersScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/admin/coaches', builder: (_, _) => const CoachesScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/admin/more',
              builder: (_, _) => MoreScreen(session: session),
              routes: [
                GoRoute(
                  path: 'packages',
                  builder: (_, _) => const PackagesScreen(),
                ),
                GoRoute(
                  path: 'equipment',
                  builder: (_, _) => const EquipmentScreen(),
                ),
                GoRoute(
                  path: 'workouts',
                  builder: (_, _) => const WorkoutLibraryScreen(),
                ),
                GoRoute(
                  path: 'gymqr',
                  builder: (_, _) => const GymQrScreen(),
                ),
                GoRoute(
                  path: 'reports',
                  builder: (_, _) => const ReportsScreen(),
                ),
                GoRoute(
                  path: 'audit',
                  builder: (_, _) => const AuditScreen(),
                ),
                GoRoute(
                  path: 'settings',
                  builder: (_, _) => const SettingsScreen(),
                ),
                GoRoute(
                  path: 'password',
                  builder: (_, _) => const ChangePasswordScreen(),
                ),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
}
