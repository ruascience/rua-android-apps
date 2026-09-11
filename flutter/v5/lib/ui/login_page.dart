import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/cloud_sync.dart';
import '../data/session.dart';
import 'kit.dart';

/// Sign in. The app shows nothing else until this succeeds.
///
/// Blocking on purpose, and for a different reason than the onboarding sheet:
/// that one blocks because a guessed age produces a believable-but-wrong
/// VO2max. This one blocks because a reading with no owner belongs to nobody —
/// the server refuses it, and a phone that collected all day and could not file
/// any of it would be worse than one that said so at the start.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  late final TextEditingController _url =
      TextEditingController(text: CloudSync.instance.baseUrl);

  bool _busy = false;
  bool _showPass = false;
  bool _showServer = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    // The address is part of signing in: a token is only valid on the server
    // that issued it, so changing one without the other produces a 401 that
    // looks like a wrong password.
    await CloudSync.instance.setBaseUrl(_url.text);

    final problem = await Session.instance.signIn(
      baseUrl: CloudSync.instance.baseUrl,
      username: _user.text,
      password: _pass.text,
      client: http.Client(),
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(Icons.show_chart, size: 22, color: kWarn),
                      const SizedBox(width: 10),
                      Text('Rua Science',
                          style: t.textTheme.headlineSmall
                              ?.copyWith(fontFamily: kSerif)),
                    ]),
                    const SizedBox(height: 10),
                    Text(
                      'Sign in so your readings are stored against you and '
                      'nobody else.',
                      style: t.textTheme.bodyMedium?.copyWith(color: kMuted),
                    ),
                    const SizedBox(height: 28),

                    TextFormField(
                      controller: _user,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                          labelText: 'Username', border: OutlineInputBorder()),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _pass,
                      obscureText: !_showPass,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: (_) => _busy ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _showPass ? 'Hide password' : 'Show password',
                          icon: Icon(
                              _showPass
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 20),
                          onPressed: () =>
                              setState(() => _showPass = !_showPass),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: kBad.withValues(alpha: 0.10),
                        child: Row(children: [
                          Icon(Icons.error_outline, size: 18, color: kBad),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(_error!,
                                  style: t.textTheme.bodySmall
                                      ?.copyWith(color: kBad))),
                        ]),
                      ),
                    ],

                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy ? 'Signing in…' : 'Sign in'),
                    ),

                    const SizedBox(height: 18),
                    // Tucked away, because a participant should never need it
                    // and a wrong address here is a confusing failure. Present,
                    // because a tester pointed at a different server has no
                    // other way in — there is no settings screen before login.
                    TextButton(
                      onPressed: () =>
                          setState(() => _showServer = !_showServer),
                      child: Text(_showServer ? 'Hide server' : 'Change server'),
                    ),
                    if (_showServer) ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _url,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                            labelText: 'Server address',
                            isDense: true,
                            border: OutlineInputBorder()),
                      ),
                    ],

                    const SizedBox(height: 24),
                    Text(
                      'Accounts are created by the study team. If you do not '
                      'have one, ask them rather than signing up — there is no '
                      'sign-up.',
                      style: t.textTheme.labelSmall?.copyWith(color: kMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
