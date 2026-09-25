import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aurav5/data/background.dart';

/// The service is what keeps a band collecting when the app is not on screen.
/// Whether it is MEANT to run and whether it HAS started are different facts,
/// and collapsing them is what left every fresh install silently not
/// collecting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh install wants the service on', () async {
    SharedPreferences.setMockInitialValues({});
    await BackgroundSync.instance.load();
    expect(BackgroundSync.instance.wanted, isTrue,
        reason: 'a participant wearing the band all day must not have to '
            'remember to open the app');
  });

  test('wanting it is not the same as having started it', () async {
    SharedPreferences.setMockInitialValues({});
    await BackgroundSync.instance.load();
    // Nothing can start in a test binding, and nothing tried to: load() must
    // not attempt a start, because the permission it needs cannot be asked
    // for before there is a frame to show the dialog on.
    expect(BackgroundSync.instance.enabled, isFalse);
  });

  test('an explicit off is remembered', () async {
    SharedPreferences.setMockInitialValues({'background.enabled': false});
    await BackgroundSync.instance.load();
    expect(BackgroundSync.instance.wanted, isFalse,
        reason: 'someone who turned it off must not have it turned back on');
  });

  test('ensureStarted does not attempt before Bluetooth permission exists',
      () async {
    // Android refuses a `connectedDevice` foreground service unless the app
    // already holds a runtime Bluetooth permission, and a refused start is
    // not a clean no-op: the service is left half-started and Android retries
    // it every five seconds. A fresh install sat in that loop, burning
    // battery and collecting nothing.
    SharedPreferences.setMockInitialValues({});
    await BackgroundSync.instance.load();
    expect(BackgroundSync.instance.wanted, isTrue);
    await BackgroundSync.instance.ensureStarted();
    expect(BackgroundSync.instance.enabled, isFalse,
        reason: 'no Bluetooth permission in a test binding, so it must not '
            'have tried');
  });

  test('ensureStarted does nothing when it is not wanted', () async {
    SharedPreferences.setMockInitialValues({'background.enabled': false});
    await BackgroundSync.instance.load();
    await BackgroundSync.instance.ensureStarted();
    expect(BackgroundSync.instance.enabled, isFalse);
  });
}
