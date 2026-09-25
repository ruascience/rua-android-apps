import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import 'kit.dart';

/// Shown when the lock is on and this run has not satisfied it.
///
/// Deliberately not dismissable and deliberately not a dialog: the data
/// behind it is somebody's heart rate and sleep, and a sheet you can swipe
/// away is not a lock.
class LockPage extends StatefulWidget {
  const LockPage({super.key});
  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // Prompt straight away. Making someone tap a button to be shown the
    // prompt they came here for is a step that exists for nobody.
    WidgetsBinding.instance.addPostFrameCallback((_) => _try());
  }

  Future<void> _try() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    final why = await AppLock.instance.unlock();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = why ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const RuaWordmark(),
                const SizedBox(height: 28),
                Icon(Icons.fingerprint, size: 56, color: kAccent),
                const SizedBox(height: 20),
                Text(
                  'Unlock to see your readings',
                  style: t.textTheme.titleMedium?.copyWith(color: kText),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your band keeps collecting and syncing while this is '
                  'locked — nothing is missed.',
                  style: t.textTheme.bodySmall
                      ?.copyWith(color: kMuted, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(_error,
                      style: t.textTheme.bodySmall?.copyWith(color: kBad),
                      textAlign: TextAlign.center),
                ],
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: _busy ? null : _try,
                  icon: const Icon(Icons.fingerprint, size: 18),
                  label: Text(_busy ? 'Waiting…' : 'Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
