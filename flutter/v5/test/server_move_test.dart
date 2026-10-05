import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aurav5/data/cloud_sync.dart';

/// Moving the server is the one change that can silently strand every phone:
/// the address is remembered, so a new default reaches fresh installs only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a phone still on the retired Azure address is moved across', () async {
    SharedPreferences.setMockInitialValues({
      'cloud.base_url': 'https://48.202.193.164:8101',
    });
    await CloudSync.instance.start();
    expect(CloudSync.instance.baseUrl, CloudSync.defaultBaseUrl,
        reason: 'otherwise everyone upgrading keeps talking to a host that is '
            'about to be switched off, and queues for ever against it');
  });

  test('the move is written back, not re-done every launch', () async {
    SharedPreferences.setMockInitialValues({
      'cloud.base_url': 'https://48.202.193.164:8101',
    });
    await CloudSync.instance.start();
    final p = await SharedPreferences.getInstance();
    expect(p.getString('cloud.base_url'), CloudSync.defaultBaseUrl);
  });

  test('an address the user typed themselves is left alone', () async {
    SharedPreferences.setMockInitialValues({
      'cloud.base_url': 'https://192.168.1.50:8101',
    });
    await CloudSync.instance.start();
    expect(CloudSync.instance.baseUrl, 'https://192.168.1.50:8101',
        reason: 'only known-retired addresses are replaced');
  });

  test('a fresh install gets the current default', () async {
    SharedPreferences.setMockInitialValues({});
    await CloudSync.instance.start();
    expect(CloudSync.instance.baseUrl, 'https://65.0.59.203');
  });
}
