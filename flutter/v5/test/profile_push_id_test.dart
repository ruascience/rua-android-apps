import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aurav5/data/profile.dart';
import 'package:aurav5/data/session.dart';

/// Resolving WHICH profile this phone is is what gates the profile push, so a
/// null here means age, sex, height, weight and period dates never leave the
/// device — silently, for ever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Session.instance.signOut();
  });

  tearDown(() async => Session.instance.signOut());

  test('a signed-in account supplies the profile id', () async {
    // The case that was broken. A new participant's band has never had a
    // profile, so the by-band lookup finds nothing; the mint gate then
    // refuses because the server DOES hold profiles — other people's. The
    // old code returned null here and deferred the push on every launch.
    Session.instance.username = 'vanishree';
    Session.instance.token = 't';
    Session.instance.profileId = '54c4386f-3fa8-491d-8943-adf55e717a8f';

    Profile.instance.markLoadedForTest();
    Profile.instance.profileId = null;
    Profile.instance.bandId = 'EB:CB:84:44:30:0D';

    final id = await Profile.instance.ensureProfileId(
      // Band is unknown to the server, and the server holds other profiles.
      lookup: (_, _) async => const ProfileLookupResult.none(),
      mintGate: () async => false,
    );

    expect(id, '54c4386f-3fa8-491d-8943-adf55e717a8f');
  });

  test('a locally minted id that disagrees is replaced by the account', () async {
    // Otherwise the profile document lands under one id while the readings
    // sit under another: the two halves of one person, filed apart.
    SharedPreferences.setMockInitialValues({});
    Session.instance.username = 'padmini';
    Session.instance.token = 't';
    Session.instance.profileId = 'account-id';

    Profile.instance.markLoadedForTest();
    Profile.instance.profileId = 'locally-minted-id';

    final id = await Profile.instance.ensureProfileId();
    expect(id, 'account-id');
    expect(Profile.instance.profileId, 'account-id',
        reason: 'and it is persisted, not just returned');
  });

  test('signed out, the old by-band behaviour is untouched', () async {
    Profile.instance.markLoadedForTest();
    Profile.instance.profileId = null;
    Profile.instance.bandId = 'EB:CB:84:44:30:0D';

    final id = await Profile.instance.ensureProfileId(
      lookup: (_, _) async => const ProfileLookupResult.none(),
      mintGate: () async => false,
    );
    expect(id, isNull,
        reason: 'with no account to ask, minting against a server that holds '
            'profiles is still how a duplicate person gets created');
  });
}
