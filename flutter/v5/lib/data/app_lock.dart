import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unlocking the app with a fingerprint or face.
///
/// ## What this is, and what it is not
///
/// It does NOT save anyone from typing a password every time — the session
/// token already persists for 90 days, so signing in happens about four times
/// a year. What it does is put a lock on data that is otherwise readable by
/// anyone holding an unlocked phone: someone else's resting heart rate, their
/// sleep, the nights they did not sleep.
///
/// So the password is still the way IN, and the fingerprint is the way BACK
/// in. That distinction matters: the password is never stored, here or
/// anywhere, and this class cannot sign anybody in. It only decides whether
/// an existing session may be used.
///
/// Off by default. A lock nobody asked for on an app they are being asked to
/// wear for a study is a reason to stop wearing it.
class AppLock {
  AppLock._();
  static final AppLock instance = AppLock._();

  static const _kEnabled = 'lock.biometric';

  final _auth = LocalAuthentication();

  bool enabled = false;

  /// True once this run has satisfied the lock, so switching tabs or coming
  /// back from the band's pairing dialog does not ask again.
  bool unlocked = false;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_kEnabled) ?? false;
    } catch (e) {
      debugPrint('[AuraV5] app lock state unavailable: $e');
      enabled = false;
    }
    // A lock that is on but cannot be satisfied would be a locked-out user
    // with no way back except reinstalling — which would take their unsent
    // readings with it. If the hardware or the enrolment has gone away,
    // the lock turns itself off and says so.
    if (enabled && !await available()) {
      debugPrint('[AuraV5] biometrics no longer available — lock disabled');
      enabled = false;
      unlocked = true;
      await _persist();
    }
    _changes.add(null);
  }

  /// Can this phone actually do it? False on a device with no sensor, or one
  /// where nothing has been enrolled.
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (e) {
      debugPrint('[AuraV5] biometric check failed: $e');
      return false;
    }
  }

  /// Ask for the fingerprint. Returns null when it succeeded, else a reason.
  Future<String?> unlock({String reason = 'Unlock Rua Science'}) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // The device PIN stays allowed on purpose: a wet or cut finger must
        // not lock somebody out of their own readings.
        biometricOnly: false,
        // Survives the prompt briefly taking focus, so a notification
        // sliding down mid-scan is not a failed unlock.
        persistAcrossBackgrounding: true,
      );
      if (ok) {
        unlocked = true;
        _changes.add(null);
        return null;
      }
      return 'Not recognised.';
    } catch (e) {
      debugPrint('[AuraV5] unlock failed: $e');
      return 'Could not use the fingerprint reader on this phone.';
    }
  }

  /// Turn the lock on, proving it works first.
  ///
  /// Enabling without a successful prompt is how a person ends up locked out
  /// by a feature they just switched on.
  Future<String?> enable() async {
    if (!await available()) {
      return 'This phone has no fingerprint or face unlock set up. Add one in '
          'Android settings first.';
    }
    final why = await unlock(reason: 'Confirm to turn on unlock');
    if (why != null) return why;
    enabled = true;
    unlocked = true;
    await _persist();
    _changes.add(null);
    return null;
  }

  Future<void> disable() async {
    enabled = false;
    unlocked = true;
    await _persist();
    _changes.add(null);
  }

  /// Re-arm on the way to the background, so returning asks again.
  void relock() {
    if (!enabled) return;
    unlocked = false;
    _changes.add(null);
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, enabled);
    } catch (_) {}
  }
}
