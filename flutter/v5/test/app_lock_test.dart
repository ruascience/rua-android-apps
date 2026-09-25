import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aurav5/data/app_lock.dart';

/// The lock guards an existing session. It can never create one, and it must
/// never be able to shut somebody out of their own readings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLock.instance.load();
  });

  test('off by default', () async {
    expect(AppLock.instance.enabled, isFalse,
        reason: 'a lock nobody asked for on a study app is a reason to stop '
            'wearing the band');
  });

  test('a stored preference cannot lock out a phone with no biometrics',
      () async {
    // No biometric hardware exists in a test binding, so `available()` is
    // false. A stored "on" must therefore disarm rather than strand the user
    // behind a prompt that can never succeed — their unsent readings would go
    // with a reinstall.
    SharedPreferences.setMockInitialValues({'lock.biometric': true});
    await AppLock.instance.load();
    expect(AppLock.instance.enabled, isFalse);
    expect(AppLock.instance.unlocked, isTrue);
  });

  test('relock does nothing while the lock is off', () {
    AppLock.instance.unlocked = true;
    AppLock.instance.relock();
    expect(AppLock.instance.unlocked, isTrue,
        reason: 'backgrounding must not gate an app whose lock is off');
  });

  test('disable always leaves the app usable', () async {
    await AppLock.instance.disable();
    expect(AppLock.instance.enabled, isFalse);
    expect(AppLock.instance.unlocked, isTrue);
  });
}
