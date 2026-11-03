import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'common.dart';

/// "Reset password" button: asks for confirmation, calls the `reset-password`
/// Edge Function, then shows the new temporary password once.
class ResetPasswordButton extends StatefulWidget {
  const ResetPasswordButton({super.key, required this.userId, required this.name});
  final String userId;
  final String name;

  @override
  State<ResetPasswordButton> createState() => _ResetPasswordButtonState();
}

class _ResetPasswordButtonState extends State<ResetPasswordButton> {
  bool _busy = false;

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password?'),
        content: Text('This sets a new temporary password for ${widget.name}. '
            'Their old password stops working straight away.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final res =
          await db.functions.invoke('reset-password', body: {'user_id': widget.userId});
      final data = res.data as Map;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _NewPasswordDialog(
            email: data['email'] as String? ?? '', password: data['password'] as String),
      );
    } on FunctionException catch (e) {
      final d = e.details;
      if (mounted) {
        snack(
            context,
            d is Map && d['error'] is String
                ? d['error'] as String
                : (e.status == 404
                    ? 'The reset-password service is not set up yet.'
                    : 'Could not reset the password.'));
      }
    } catch (_) {
      if (mounted) snack(context, 'Could not reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _reset,
      icon: const Icon(Icons.lock_reset),
      label: Text(_busy ? 'Resetting...' : 'Reset password'),
    );
  }
}

class _NewPasswordDialog extends StatelessWidget {
  const _NewPasswordDialog({required this.email, required this.password});
  final String email;
  final String password;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New temporary password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Email: $email'),
          const SizedBox(height: 8),
          SelectableText('Password: $password'),
          const SizedBox(height: 12),
          const Text('This password is shown only once. Pass it on privately and '
              'ask them to change it under More > Change password.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: password));
            if (context.mounted) snack(context, 'Password copied');
          },
          child: const Text('Copy password'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
