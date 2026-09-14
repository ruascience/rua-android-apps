import 'package:flutter/material.dart';

import '../data/cloud_sync.dart';
import '../data/session.dart';
import 'kit.dart';

/// Create your own account.
///
/// Added because waiting on an admin to be let in, once per person, does not
/// scale past a handful of participants — and the person holding the band is
/// the one who wants to start.
///
/// What keeps this from being an open door is the study join code, checked
/// server-side. The phone asks the server whether a code is needed rather
/// than assuming, so a deployment that opens sign-up to anyone does not have
/// to ship a different build.
class RegisterPage extends StatefulWidget {
  final RegistrationPolicy policy;
  const RegisterPage({super.key, required this.policy});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _name = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _again = TextEditingController();
  final _code = TextEditingController();

  bool _busy = false;
  bool _show = false;
  String _error = '';

  @override
  void dispose() {
    for (final c in [_name, _user, _pass, _again, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Checked here as well as on the server, because a round trip to be told
  /// "that is too short" is a round trip that did not need to happen.
  String? _localProblem() {
    if (_name.text.trim().isEmpty) return 'Enter your name.';
    if (_user.text.trim().length < 3) {
      return 'Pick a username of at least 3 characters.';
    }
    if (_user.text.trim().contains(RegExp(r'\s'))) {
      return 'A username cannot contain spaces.';
    }
    if (_pass.text.length < 8) {
      return 'Use a password of at least 8 characters.';
    }
    if (_pass.text != _again.text) return 'The two passwords do not match.';
    if (widget.policy.codeRequired && _code.text.trim().isEmpty) {
      return 'Enter the join code the study team gave you.';
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _localProblem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });

    final err = await Session.instance.register(
      baseUrl: CloudSync.instance.baseUrl,
      username: _user.text,
      password: _pass.text,
      displayName: _name.text,
      joinCode: _code.text,
      // The pinned client: the server's certificate is self-signed and a
      // default client refuses it before the request is even sent.
      client: CloudSync.pinnedClient(),
    );

    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    // Signed in already — the shell takes over from the session gate.
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Create an account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          children: [
            Text(
              'Your readings are stored against this account and nobody '
              'else\'s. Pick something you will remember — there is no '
              'password reset in the app yet, so a forgotten one means asking '
              'the study team.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name',
                helperText: 'Shown to the study team, not used to sign in',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _user,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText: 'No spaces. This is what you sign in with.',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _pass,
              obscureText: !_show,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: 'At least 8 characters',
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _again,
              obscureText: !_show,
              decoration: const InputDecoration(labelText: 'Password again'),
            ),
            if (widget.policy.codeRequired) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _code,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Join code',
                  helperText: 'Given to you with your band',
                ),
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(_error, style: t.textTheme.bodySmall?.copyWith(color: kBad)),
            ],
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}
