import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum UserRole { admin, coach, member }

enum SessionStatus { loading, signedOut, signedIn }

/// Holds who is logged in and what role they have. The router watches this.
class AppSession extends ChangeNotifier {
  AppSession() {
    _sub = _auth.onAuthStateChange.listen((_) => _refresh());
    _refresh();
  }

  GoTrueClient get _auth => Supabase.instance.client.auth;
  late final StreamSubscription<AuthState> _sub;

  SessionStatus status = SessionStatus.loading;
  UserRole? role;
  String fullName = '';

  /// Shown on the login screen (e.g. "account is switched off").
  String? notice;

  /// Set while a logged-in user's profile could not be loaded (e.g. offline).
  String? loadError;

  bool _busy = false;

  /// Called by the Retry button on the loading screen.
  Future<void> retry() {
    loadError = null;
    notifyListeners();
    return _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      loadError = null;
      if (_auth.currentSession == null) {
        _set(SessionStatus.signedOut, null, '');
        return;
      }
      final row = await Supabase.instance.client
          .from('profiles')
          .select('role, full_name, is_active')
          .eq('id', _auth.currentUser!.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));

      if (row == null) {
        await _rejectLogin(
            'This login has no RepClub profile. Please contact the gym.');
      } else if (row['is_active'] != true) {
        await _rejectLogin(
            'This account has been switched off. Please contact the gym.');
      } else {
        notice = null;
        _set(
          SessionStatus.signedIn,
          _parseRole(row['role'] as String),
          (row['full_name'] as String?) ?? '',
        );
      }
    } catch (_) {
      // Offline or server hiccup: keep the login, let the user retry.
      if (_auth.currentSession != null) {
        loadError =
            'Could not load your account. Check your connection and try again.';
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _rejectLogin(String message) async {
    notice = message;
    await _auth.signOut();
    _set(SessionStatus.signedOut, null, '');
  }

  void _set(SessionStatus s, UserRole? r, String name) {
    status = s;
    role = r;
    fullName = name;
    notifyListeners();
  }

  static UserRole _parseRole(String value) => switch (value) {
        'ADMIN' => UserRole.admin,
        'COACH' => UserRole.coach,
        _ => UserRole.member,
      };

  /// Returns an error message, or null on success.
  Future<String?> signIn(String email, String password) async {
    notice = null;
    try {
      await _auth.signInWithPassword(email: email.trim(), password: password);
      // The auth listener loads the profile; wait for it to finish.
      while (_busy) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (status != SessionStatus.signedIn) await _refresh();
      return notice;
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('invalid login')) {
        return 'Wrong email or password.';
      }
      return e.message;
    } catch (_) {
      return 'Could not reach the server. Check your connection.';
    }
  }

  Future<void> signOut() => _auth.signOut();

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
