import 'dart:convert';

import 'package:aurav5/data/cloud_sync.dart';
import 'package:aurav5/data/profile.dart';
import 'package:aurav5/data/store.dart';
import 'package:aurav5/data/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Identity, which is the half of this change that can go wrong silently.
///
/// The profile's `_id` stopped being the band's advertised name and became a
/// UUID. Everything here exists to pin the one failure that follows from
/// getting that wrong: a phone that mints its own id for a person the server
/// already knows, leaving the user with TWO profiles — one holding their
/// history and one holding their name — and nothing in the app able to merge
/// them.

/// A canonical v4 UUID: version nibble 4, variant nibble 8/9/a/b.
final _v4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Wrap a handler so the server also answers the mint gate.
///
/// `GET /api/v1/summary` reporting `profiles: 0` is what tells the app it is
/// safe to mint: a server holding no profiles has nothing to duplicate. Every
/// test below that expects an id to be MINTED has to serve it, because a 404
/// from the by-band lookup is deliberately no longer enough on its own — see
/// the tests that pin exactly that.
http.Client _server(Future<http.Response> Function(http.Request) handle,
    {Object? profiles = 0}) {
  return MockClient((req) async {
    if (req.method == 'GET' && req.url.path.endsWith('/api/v1/summary')) {
      return http.Response(
          jsonEncode({
            'samples': 0,
            'profiles': ?profiles,
          }),
          200);
    }
    return handle(req);
  });
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Store.instance.resetForTest();

    // Deliberately NOT markLoadedForTest: load() is idempotent by design, so
    // the one test below that exercises it has to be the only caller in this
    // file. Nothing else here needs the flag.
    final p = Profile.instance;
    p.profileId = null;
    p.phoneNumber = '';
    p.email = '';
    p.name = 'Gajendran';
    p.age = 48;
    p.sex = Sex.male;
    p.heightCm = 183;
    p.weightKg = 137;
    p.periodStarts = [];
    p.onboarded = true;
    p.bandId = 'AA:BB:CC:DD:EE:FF';
    p.bandDisplayName = 'JCV5 BE8D18';

    final c = CloudSync.instance;
    c.enabled = true;
    c.state = CloudState.idle;
    c.lastError = '';
  });

  group('the UUID is a UUID, not 128 bits that look like one', () {
    test('it is canonical, and says version 4 and variant 1', () {
      for (var i = 0; i < 200; i++) {
        expect(uuidV4(), matches(_v4),
            reason: 'a parser entitled to check the version nibble — '
                'UUID.fromString, Mongo\'s UUID subtype — may reject an id '
                'that claims nothing');
      }
    });

    test('two draws are never the same one', () {
      final seen = {for (var i = 0; i < 2000; i++) uuidV4()};
      expect(seen, hasLength(2000),
          reason: 'Random.secure(), not the clock-seeded default: two phones '
              'onboarding in the same millisecond must not mint the same id');
    });
  });

  group('the v5 schema step', () {
    test('a fresh database has the three identity columns', () async {
      final d = await Store.instance.db;
      final cols = {
        for (final r in await d.rawQuery('PRAGMA table_info(profile)'))
          r['name'] as String
      };
      expect(cols, containsAll(['profile_id', 'phone', 'email']));
    });

    test('it adds them to a v4 table without touching the row that is there',
        () async {
      // The property that matters on the real phone: 55,779 samples and a
      // profile that took an undismissable first-run sheet to collect. An
      // upgrade that rewrites rows is indistinguishable from data loss.
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final d = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            // The v4 profile table, verbatim.
            await db.execute('''
              CREATE TABLE profile (
                id        INTEGER PRIMARY KEY CHECK (id = 1),
                name      TEXT    NOT NULL DEFAULT '',
                age       INTEGER NOT NULL,
                sex       INTEGER NOT NULL,
                height_cm INTEGER NOT NULL,
                weight_kg REAL    NOT NULL,
                onboarded INTEGER NOT NULL DEFAULT 0
              )
            ''');
          },
        ),
      );
      await d.insert('profile', {
        'id': 1,
        'name': 'Gajendran',
        'age': 48,
        'sex': 1,
        'height_cm': 183,
        'weight_kg': 137.0,
        'onboarded': 1,
      });

      await Store.upgradeProfileIdentityForTest(d);
      // Twice: ALTER TABLE throws on a column that is already there, and an
      // upgrade that only survives being run once is one crash away from a
      // phone that will not open its own database.
      await Store.upgradeProfileIdentityForTest(d);

      final row = (await d.query('profile')).single;
      expect(row['name'], 'Gajendran');
      expect(row['age'], 48);
      expect(row['height_cm'], 183);
      expect(row['weight_kg'], 137.0);
      expect(row['onboarded'], 1);
      expect(row['profile_id'], isNull,
          reason: 'NULL is the honest answer for a row nobody ever asked');
      expect(row['phone'], isNull);
      expect(row['email'], isNull);
      await d.close();
    });
  });

  group('what the profile stores', () {
    test('onboarding carries phone and email into SQLite', () async {
      await Profile.instance.completeOnboarding(
        name: 'Gajendran',
        age: 48,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
        phoneNumber: ' +44 20 7946 0018 ',
        email: '  gaj@example.com ',
      );
      final row = await Store.instance.readProfile();
      expect(row!['phone'], '+44 20 7946 0018',
          reason: 'stored as the validator judged it — trimmed');
      expect(row['email'], 'gaj@example.com');
    });

    test('blank is stored as NULL, so "not answered" has one spelling',
        () async {
      await Profile.instance.completeOnboarding(
        name: 'Gajendran',
        age: 48,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
        phoneNumber: '',
        email: '   ',
      );
      final row = await Store.instance.readProfile();
      expect(row!['phone'], isNull);
      expect(row['email'], isNull);
      expect(Profile.instance.email, '',
          reason: 'in memory it stays a String — the screens bind it to a '
              'text field');
    });

    test('an edit CLEARS a contact detail when the field is emptied',
        () async {
      await Profile.instance.completeOnboarding(
        name: 'Gajendran',
        age: 48,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
        email: 'old@example.com',
      );
      await Profile.instance.updateDetails(
        name: 'Gajendran',
        age: 48,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
        email: '',
      );
      expect(Profile.instance.email, '');
      expect((await Store.instance.readProfile())!['email'], isNull,
          reason: 'deleting an address that is no longer yours is an edit, '
              'not a no-op');
    });

    test('a save that never mentions them leaves them alone', () async {
      await Profile.instance.completeOnboarding(
        name: 'Gajendran',
        age: 48,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
        email: 'keep@example.com',
      );
      // The Device tab's own writes, rememberBand, logPeriodStart — none of
      // them show a contact field, so none of them may wipe one.
      await Profile.instance.updateDetails(
        name: 'Gajendran',
        age: 49,
        sex: Sex.male,
        heightCm: 183,
        weightKg: 137,
      );
      expect(Profile.instance.email, 'keep@example.com');
      expect((await Store.instance.readProfile())!['email'],
          'keep@example.com');
    });

    test('an unrelated write does not erase the id', () async {
      Profile.instance.profileId = 'e1d4a6f0-0000-4000-8000-000000000001';
      await Profile.instance.logPeriodStart(DateTime(2026, 8, 27));
      expect((await Store.instance.readProfile())!['profile_id'],
          'e1d4a6f0-0000-4000-8000-000000000001',
          reason: 'writeProfile REPLACEs the whole row — a writer that '
              'forgot a column would blank the id this change exists to keep');
    });

    // The only load() in this file: it is idempotent on purpose, so a second
    // caller would silently test nothing.
    test('the id, phone and email come back after a restart', () async {
      await Store.instance.writeProfile(
        name: 'Gajendran',
        age: 48,
        sex: 1,
        heightCm: 183,
        weightKg: 137,
        onboarded: true,
        profileId: 'c0ffee00-0000-4000-8000-0000000000ff',
        phone: '+44 20 7946 0018',
        email: 'gaj@example.com',
      );
      Profile.instance.profileId = null;
      Profile.instance.phoneNumber = '';
      Profile.instance.email = '';

      await Profile.instance.load();

      expect(Profile.instance.profileId, 'c0ffee00-0000-4000-8000-0000000000ff');
      expect(Profile.instance.phoneNumber, '+44 20 7946 0018');
      expect(Profile.instance.email, 'gaj@example.com');
    });
  });

  group('the two-UUID trap', () {
    test('the server\'s id is ADOPTED rather than a second one minted',
        () async {
      const serverId = '9b2f7c14-3d51-4a08-9f6e-2c4d7e8a1b03';
      Uri? asked;
      final puts = <Map<String, Object?>>[];
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.method == 'GET') {
          asked = req.url;
          return http.Response(
              jsonEncode({'_id': serverId, 'device': 'JCV5 BE8D18'}), 200);
        }
        puts.add(jsonDecode(req.body) as Map<String, Object?>);
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, serverId);
      expect(puts.single['id'], serverId,
          reason: 'the push must go to the document that already holds the '
              'history, not to a new one beside it');
      expect(asked!.pathSegments.last, 'AA:BB:CC:DD:EE:FF',
          reason: 'asked by BLE ADDRESS — the advertised name is mutable and '
              'this band renamed itself mid-session');
      expect(asked!.queryParameters['device'], 'JCV5 BE8D18',
          reason: 'the migrated document has no band_id — the phone is the '
              'only thing that knows the address — so the advertised name '
              'rides along as the fallback the server can match on');
    });

    test('the advertised name is tried as a path too, for the migrated row',
        () async {
      // The likelier API shape: one path variable matched against band_id OR
      // device. Whichever of the two spellings the server implements, the
      // document that has no band_id yet still has to be found.
      const serverId = '9b2f7c14-3d51-4a08-9f6e-2c4d7e8a1b03';
      final keys = <String>[];
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.method == 'GET') {
          final key = req.url.pathSegments.last;
          keys.add(key);
          return key == 'JCV5 BE8D18'
              ? http.Response(jsonEncode({'_id': serverId}), 200)
              : http.Response('{"error":"not found"}', 404);
        }
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(keys, ['AA:BB:CC:DD:EE:FF', 'JCV5 BE8D18']);
      expect(Profile.instance.profileId, serverId);
    });

    test('a definite 404 AND an empty server is the licence to mint',
        () async {
      final puts = <Map<String, Object?>>[];
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        puts.add(jsonDecode(req.body) as Map<String, Object?>);
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, matches(_v4));
      expect(puts.single['id'], Profile.instance.profileId);
    });

    test('a 404 alone is NOT a licence — a server holding a profile it could '
        'not match mints nothing', () async {
      // The failure this whole group exists for, in its most honest form.
      // 404 means "I did not find it", and there are at least three ways to
      // not find a profile that is really there: the migration files it under
      // ONE band's advertised name and this user has two; an un-migrated
      // document carries neither band_id nor device to match on; a server
      // older than this app has no by-band route, so the 404 is the URL. A
      // COUNT is immune to all three.
      var puts = 0;
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        puts++;
        return http.Response('{}', 200);
      }, profiles: 1);

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull,
          reason: 'somebody is already in there; minting beside them is the '
              'duplicate this cannot be allowed to make');
      expect(puts, 0);
    });

    test('a server too old to report a count mints nothing', () async {
      // The app updating before the API does. Absence of the key is not zero,
      // and reading it as zero is how the phone mints a rival for a profile
      // the next deploy is about to expose.
      var puts = 0;
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        puts++;
        return http.Response('{}', 200);
      }, profiles: null);

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull);
      expect(puts, 0);
    });

    test('every band this phone has history with is offered before minting',
        () async {
      // The profile is filed under the advertised name that used to be its
      // _id, which is ONE of this phone's two bands — and bandDisplayName is
      // whichever was connected last. 62% of this user's samples came from
      // the band that is NOT the one the profile is filed under.
      const serverId = '9b2f7c14-3d51-4a08-9f6e-2c4d7e8a1b03';
      final d = await Store.instance.db;
      for (final e in {'JCV5 6C6BB3': 1, 'JCV5 BE8D18': 2}.entries) {
        await d.insert('samples', {
          'device': e.key,
          'metric': 'heart_rate',
          'at': 1788193320000 + e.value,
          'value': 60.0,
        });
      }
      // The band on the wrist right now is the one the profile is NOT under.
      Profile.instance.bandDisplayName = 'JCV5 6C6BB3';

      final keys = <String>[];
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') {
          final key = req.url.pathSegments.last;
          keys.add(key);
          return key == 'JCV5 BE8D18'
              ? http.Response(jsonEncode({'_id': serverId}), 200)
              : http.Response('{}', 404);
        }
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(keys, contains('JCV5 BE8D18'),
          reason: 'the OTHER band in the samples table has to be offered — '
              'asking only about the connected one is how the phone walks '
              'past its own profile and mints a second');
      expect(Profile.instance.profileId, serverId);
    });

    test('an unreachable server mints NOTHING and pushes nothing', () async {
      var puts = 0;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.method == 'GET') throw const _TransportFailure();
        puts++;
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull,
          reason: '"I could not ask" is not "there is none" — minting on '
              'silence is exactly how the duplicate gets made');
      expect(puts, 0, reason: 'a profile with no id must never be pushed');
    });

    test('a 500 is not an answer either', () async {
      var puts = 0;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.method == 'GET') return http.Response('boom', 500);
        puts++;
        return http.Response('{}', 200);
      });
      await CloudSync.instance.flush();
      expect(Profile.instance.profileId, isNull);
      expect(puts, 0);
    });

    test('a 200 whose body has no id is treated as unknown, not as none',
        () async {
      CloudSync.instance.clientForTest = MockClient((req) async =>
          req.method == 'GET'
              ? http.Response('{"device":"JCV5 BE8D18"}', 200)
              : http.Response('{}', 200));
      await CloudSync.instance.flush();
      expect(Profile.instance.profileId, isNull,
          reason: 'a profile came back and we could not tell what it is '
              'called; guessing is the one thing that cannot be undone');
    });

    test('a 404 from an API that has no by-band route does NOT mint',
        () async {
      // The sequence that still ends in two profiles if this is got wrong:
      // the app ships before the API does, every by-band call 404s because
      // the route does not exist, and a phone that reads that as "no profile
      // for this band" mints an id it can never take back — then pushes it
      // beside the migrated document the moment the API catches up.
      var puts = 0;
      CloudSync.instance.clientForTest = MockClient((req) async {
        if (req.method == 'GET') {
          final legacy = !req.url.path.contains('by-band');
          // What the live server looks like today: one profile, filed under
          // the band's advertised name, and no by-band route at all.
          return legacy && req.url.pathSegments.last == 'JCV5 BE8D18'
              ? http.Response(
                  jsonEncode({'device': 'JCV5 BE8D18', 'name': 'Gajendran'}),
                  200)
              : http.Response('{"status":404,"error":"Not Found"}', 404);
        }
        puts++;
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull,
          reason: 'a profile for this band exists — whatever it is called, '
              'this phone does not get to invent a second one');
      expect(puts, 0);
    });

    test('once settled the id is never asked for or regenerated again',
        () async {
      var gets = 0;
      final puts = <Map<String, Object?>>[];
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') {
          gets++;
          return http.Response('{}', 404);
        }
        puts.add(jsonDecode(req.body) as Map<String, Object?>);
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();
      final minted = Profile.instance.profileId;
      // Four, and the summary the helper answers is not counted among them.
      // The BLE address; then the advertised name, because the document this
      // is hunting for has no band_id until the push below writes one; then
      // the old pre-UUID key, to be sure the 404s came from a server that has
      // the route rather than one that has never heard of it.
      expect(gets, 3);

      await CloudSync.instance.flush();
      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, minted);
      expect(gets, 3,
          reason: 'the question is asked until it is answered and then never '
              'again — a stored id is not re-checked against the server');
      expect(puts.map((e) => e['id']).toSet(), {minted},
          reason: 'a regenerated id orphans everything pushed under the '
              'first one');
    });
  });

  group('the failure has to be visible', () {
    test('a 4xx on the profile PUT survives the end of flush', () async {
      // The epilogue runs three lines after _pushProfile and sets
      // `state = idle; lastError = ''` unless something says otherwise.
      // _pushProfile reporting into those two fields directly was therefore a
      // report that erased itself before anyone could read it.
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        return http.Response('{"error":"validation"}', 400);
      });

      await CloudSync.instance.flush();

      expect(CloudSync.instance.state, CloudState.error,
          reason: 'a server that refuses the profile must not leave the '
              'Device tab reading "Up to date"');
      expect(CloudSync.instance.lastError, contains('400'));
    });

    test('deferring says so instead of reporting a clean sync', () async {
      // Deferring is correct — it is the whole defence — but a deferral that
      // never ends and never speaks is indistinguishable from success.
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        return http.Response('{}', 200);
      }, profiles: 2);

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull);
      expect(CloudSync.instance.lastError, isNotEmpty,
          reason: 'the phone is waiting for the server to identify this band '
              'and nothing else in the app can say so');
    });
  });

  group('what may be adopted', () {
    test('a non-UUID id is NOT adopted, and does not licence minting',
        () async {
      // The pre-migration key is the band's ADVERTISED NAME. Adopting it would
      // leave the phone pushing to a document the migration is about to move
      // to a UUID — the same duplicate through the other door — and the id is
      // permanent once stored.
      var puts = 0;
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'_id': 'JCV5 BE8D18'}), 200);
        }
        puts++;
        return http.Response('{}', 200);
      });

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, isNull,
          reason: 'neither adopted nor replaced with one of our own — a '
              'document we cannot name is a reason to wait');
      expect(puts, 0);
    });

    test('a canonical v4 UUID still is', () async {
      const serverId = '9b2f7c14-3d51-4a08-9f6e-2c4d7e8a1b03';
      CloudSync.instance.clientForTest = _server((req) async =>
          req.method == 'GET'
              ? http.Response(jsonEncode({'_id': serverId}), 200)
              : http.Response('{}', 200));

      await CloudSync.instance.flush();

      expect(Profile.instance.profileId, serverId);
    });
  });

  group('what the profile push sends', () {
    Future<Map<String, Object?>> push() async {
      Map<String, Object?>? body;
      CloudSync.instance.clientForTest = _server((req) async {
        if (req.method == 'GET') return http.Response('{}', 404);
        body = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response('{}', 200);
      });
      await CloudSync.instance.flush();
      return body!;
    }

    test('the id, the band and the contact details', () async {
      Profile.instance.phoneNumber = '+44 20 7946 0018';
      Profile.instance.email = 'gaj@example.com';

      final body = await push();

      expect(body['id'], matches(_v4));
      expect(body['bandId'], 'AA:BB:CC:DD:EE:FF',
          reason: 'the BLE ADDRESS is the real band id; the advertised name '
              'is what renamed itself from "JCV8B 44300D" to "V5"');
      expect(body['device'], 'JCV5 BE8D18',
          reason: 'device stays — it is what the samples are filed under');
      expect(body['phoneNumber'], '+44 20 7946 0018');
      expect(body['email'], 'gaj@example.com');
      expect(body['name'], 'Gajendran');
      expect(body['age'], 48);
    });

    test('a cleared detail travels as null, so the server clears it too',
        () async {
      final body = await push();
      expect(body.containsKey('email'), isTrue);
      expect(body['email'], isNull);
      expect(body['phoneNumber'], isNull);
    });

    test('an unknown band id is omitted rather than sent as null', () async {
      // Nulling a band id on the server would erase identity to say nothing.
      // The contact fields above are the opposite case: clearing one is
      // something the user meant.
      Profile.instance.bandId = null;
      final body = await push();
      expect(body.containsKey('bandId'), isFalse);
      expect(body['id'], matches(_v4),
          reason: 'with no band there is no band-keyed document to collide '
              'with, so this is the genuinely fresh case');
    });

    test('an un-onboarded profile is still not pushed', () async {
      Profile.instance.onboarded = false;
      var calls = 0;
      CloudSync.instance.clientForTest = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      await CloudSync.instance.flush();
      expect(calls, 0);
      expect(Profile.instance.profileId, isNull,
          reason: 'nothing to identify yet — the sheet has not run');
    });
  });
}

/// A stand-in for a connection failure, as in cloud_sync_test.
class _TransportFailure implements Exception {
  const _TransportFailure();
  @override
  String toString() => 'SocketException: Connection refused';
}
