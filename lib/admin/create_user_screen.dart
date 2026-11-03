import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/avatar.dart';
import '../shared/common.dart';

/// Creates a real member or coach login by calling the `create-user` Edge
/// Function (the app itself cannot create logins). Pops `true` on success.
class CreateUserScreen extends StatefulWidget {
  const CreateUserScreen({super.key, required this.isCoach});
  final bool isCoach;

  @override
  State<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends State<CreateUserScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _mobile = TextEditingController();
  final _emergency = TextEditingController();
  final _password = TextEditingController();
  String? _coach;
  Uint8List? _photo; // optional profile picture, uploaded after the login exists
  List<Map<String, dynamic>> _coaches = [];
  bool _saving = false;
  bool _hidePassword = true;

  @override
  void initState() {
    super.initState();
    if (!widget.isCoach) {
      db
          .from('profiles')
          .select('id, full_name')
          .eq('role', 'COACH')
          .eq('is_active', true)
          .order('full_name')
          .then((rows) {
        if (mounted) setState(() => _coaches = List<Map<String, dynamic>>.from(rows));
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _mobile, _emergency, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final res = await db.functions.invoke('create-user', body: {
        'role': widget.isCoach ? 'COACH' : 'MEMBER',
        'full_name': _name.text.trim(),
        'email': _email.text.trim(),
        'mobile': _mobile.text.trim(),
        'password': _password.text.trim(),
        if (!widget.isCoach) 'primary_coach_id': _coach,
        if (!widget.isCoach) 'emergency_contact': _emergency.text.trim(),
      });
      final data = res.data as Map;
      String? photoNote;
      if (_photo != null) {
        try {
          await uploadAvatar(data['id'] as String, _photo!);
        } catch (_) {
          photoNote = 'The photo could not be uploaded. Add it later from '
              'their profile.';
        }
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CreatedDialog(
          email: data['email'] as String,
          password: data['password'] as String?,
          note: photoNote,
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on FunctionException catch (e) {
      final d = e.details;
      final message = d is Map && d['error'] is String
          ? d['error'] as String
          : (e.status == 404
              ? 'The create-user service is not set up yet.'
              : 'Could not create the login.');
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      snack(context, 'Could not reach the server. Check your connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    final what = widget.isCoach ? 'coach' : 'member';
    return Scaffold(
      appBar: AppBar(title: Text('New $what')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AvatarPicker(name: _name.text, onPicked: (b) => _photo = b),
            gap,
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Full name', border: OutlineInputBorder()),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            gap,
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  labelText: 'Email (used to sign in)',
                  border: OutlineInputBorder()),
              validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                      .hasMatch((v ?? '').trim())
                  ? null
                  : 'Enter a valid email address',
            ),
            gap,
            TextFormField(
              controller: _mobile,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Mobile (optional)', border: OutlineInputBorder()),
            ),
            if (!widget.isCoach) ...[
              gap,
              DropdownButtonFormField<String?>(
                initialValue: _coach,
                decoration: const InputDecoration(
                    labelText: 'Primary coach', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No coach (gym only)')),
                  for (final c in _coaches)
                    DropdownMenuItem(
                        value: c['id'] as String,
                        child: Text(c['full_name'] as String? ?? '')),
                ],
                onChanged: (v) => setState(() => _coach = v),
              ),
              gap,
              TextFormField(
                controller: _emergency,
                decoration: const InputDecoration(
                    labelText: 'Emergency contact (optional)',
                    border: OutlineInputBorder()),
              ),
            ],
            gap,
            TextFormField(
              controller: _password,
              obscureText: _hidePassword,
              decoration: InputDecoration(
                labelText: 'Password (optional)',
                helperText: 'Leave blank and one will be generated for you',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _hidePassword ? Icons.visibility : Icons.visibility_off),
                  onPressed: () =>
                      setState(() => _hidePassword = !_hidePassword),
                ),
              ),
              validator: (v) {
                final t = (v ?? '').trim();
                return t.isNotEmpty && t.length < 8
                    ? 'At least 8 characters'
                    : null;
              },
            ),
            gap,
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Create $what'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreatedDialog extends StatelessWidget {
  const _CreatedDialog(
      {required this.email, required this.password, this.note});
  final String email;
  final String? password;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Login created'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Email: $email'),
          if (password != null) ...[
            const SizedBox(height: 8),
            SelectableText('Password: $password'),
            const SizedBox(height: 12),
            const Text(
                'This password is shown only once. Copy it and pass it on '
                'privately.'),
          ] else ...[
            const SizedBox(height: 8),
            const Text('They sign in with the password you entered.'),
          ],
          if (note != null) ...[
            const SizedBox(height: 12),
            Text(note!),
          ],
        ],
      ),
      actions: [
        if (password != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: password!));
              if (context.mounted) snack(context, 'Password copied');
            },
            child: const Text('Copy password'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
