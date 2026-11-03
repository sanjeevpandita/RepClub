import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'common.dart';

/// Lets any signed-in user change their own password.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_current.text.isEmpty) {
      setState(() => _error = 'Enter your current password.');
      return;
    }
    if (_new.text.length < 8) {
      setState(() => _error = 'The new password must be at least 8 characters.');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = 'The two new passwords do not match.');
      return;
    }
    if (_new.text == _current.text) {
      setState(() => _error = 'The new password must be different.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = db.auth.currentUser?.email;
      if (email == null) throw const AuthException('No email on this login');
      // Check the current password first.
      try {
        await db.auth.signInWithPassword(email: email, password: _current.text);
      } on AuthException {
        setState(() => _error = 'Your current password is wrong.');
        return;
      }
      await db.auth.updateUser(UserAttributes(password: _new.text));
      if (!mounted) return;
      snack(context, 'Password changed');
      Navigator.of(context).maybePop();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not change the password. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
        labelText: label, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
              controller: _current,
              obscureText: !_show,
              decoration: deco('Current password')),
          const SizedBox(height: 16),
          TextField(
              controller: _new,
              obscureText: !_show,
              decoration: deco('New password (8+ characters)')),
          const SizedBox(height: 16),
          TextField(
              controller: _confirm,
              obscureText: !_show,
              decoration: deco('Repeat new password')),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _show,
            onChanged: (v) => setState(() => _show = v ?? false),
            title: const Text('Show passwords'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Change password'),
          ),
        ],
      ),
    );
  }
}
