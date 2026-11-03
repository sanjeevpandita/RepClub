import 'package:flutter/material.dart';

import 'auth/app_session.dart';
import 'router.dart';

/// Brand colours (from the RepClub website).
const repLime = Color(0xFFAAFF00);
const repBlack = Color(0xFF0B0B0B);
const repCharcoal = Color(0xFF262524);
const repPanel = Color(0xFF1A1A19);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: repLime,
    brightness: Brightness.dark,
  ).copyWith(
    primary: repLime,
    onPrimary: Colors.black,
    secondary: repLime,
    onSecondary: Colors.black,
    secondaryContainer: const Color(0xFF33440A),
    onSecondaryContainer: repLime,
    surface: repBlack,
    onSurface: Colors.white,
    surfaceContainerLowest: repBlack,
    surfaceContainerLow: repPanel,
    surfaceContainer: repPanel,
    surfaceContainerHigh: repCharcoal,
    surfaceContainerHighest: repCharcoal,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: repBlack,
    appBarTheme: const AppBarTheme(
      backgroundColor: repCharcoal,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: repCharcoal,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: const CardThemeData(
      color: repPanel,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        minimumSize: const Size.fromHeight(52),
      ),
    ),
  );
}

class RepClubApp extends StatefulWidget {
  const RepClubApp({super.key});

  @override
  State<RepClubApp> createState() => _RepClubAppState();
}

class _RepClubAppState extends State<RepClubApp> {
  final session = AppSession();
  late final router = buildRouter(session);

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'RepClub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: router,
    );
  }
}
