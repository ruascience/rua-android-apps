import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aurav5/data/collecting.dart';
import 'package:aurav5/data/session.dart';
import 'package:aurav5/data/store.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// Collecting on somebody else's behalf is the one piece of state where being
/// wrong is silent: a band synced under the wrong person produces a complete,
/// plausible dataset that nothing afterwards can tell from the real thing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Collecting.instance.load();
    await Store.instance.resetForTest();
  });

  tearDown(() async => Collecting.instance.select(null));

  group('the selection itself', () {
    test('nothing selected means the signed-in person', () async {
      expect(Collecting.instance.active, isFalse);
      expect(Collecting.instance.profileId, isNull);
    });

    test('a selection survives a reload', () async {
      await Collecting.instance.select('p-123', displayName: 'Gajendran');
      await Collecting.instance.load();
      expect(Collecting.instance.profileId, 'p-123');
      expect(Collecting.instance.displayName, 'Gajendran');
    });

    test('clearing forgets the name as well as the id', () async {
      await Collecting.instance.select('p-123', displayName: 'Gajendran');
      await Collecting.instance.clear();
      expect(Collecting.instance.profileId, isNull);
      expect(Collecting.instance.displayName, isNull);
    });

    test('an empty id is not a selection', () async {
      await Collecting.instance.select('', displayName: 'nobody');
      expect(Collecting.instance.active, isFalse);
    });
  });

  group('when collecting is blocked', () {
    test('an admin with nobody chosen cannot collect', () async {
      Session.instance.role = 'admin';
      expect(Collecting.instance.blocked, isTrue,
          reason: 'the server refuses an admin that does not name a profile, '
              'and that must not arrive one 403 per batch');
      Session.instance.role = null;
    });

    test('an admin who has chosen somebody can collect', () async {
      Session.instance.role = 'admin';
      await Collecting.instance.select('p-123', displayName: 'Gajendran');
      expect(Collecting.instance.blocked, isFalse);
      Session.instance.role = null;
    });

    test('an ordinary participant is never blocked', () async {
      Session.instance.role = 'user';
      expect(Collecting.instance.blocked, isFalse);
      Session.instance.role = null;
    });
  });

  group('the stamp lands on the row', () {
    Future<List<Map<String, Object?>>> rows() async =>
        (await Store.instance.unsyncedSamples()).toList();

    test('readings written with nobody selected carry no owner', () async {
      await Store.instance.putSamples(
          'JCV8B 44300D', 'heart_rate', [Sample(DateTime(2026, 9, 14, 9), 61)]);
      expect((await rows()).single['owner'], isNull,
          reason: 'null means "whoever is signed in", which is what every '
              'ordinary participant writes and what every pre-existing row '
              'already meant');
    });

    test('readings written while collecting carry the participant', () async {
      await Collecting.instance.select('p-123', displayName: 'Gajendran');
      await Store.instance.putSamples(
          'JCV8B 44300D', 'heart_rate', [Sample(DateTime(2026, 9, 14, 9), 61)]);
      expect((await rows()).single['owner'], 'p-123');
    });

    test('sleep is stamped the same way', () async {
      await Collecting.instance.select('p-123', displayName: 'Gajendran');
      await Store.instance.putSleepSegments('JCV8B 44300D', [
        j.SleepSegment(DateTime(2026, 9, 14, 1), 90, const [1, 2, 2, 1]),
      ]);
      final s = await Store.instance.unsyncedSleep();
      expect(s.single['owner'], 'p-123');
    });

    test('changing the selection does NOT re-attribute queued rows', () async {
      // The failure this prevents: an admin collects for one participant
      // while offline, switches to the next, and the first person's backlog
      // drains under the second person's name. Ownership is decided when the
      // reading is written, never when it happens to upload.
      await Collecting.instance.select('p-aaa', displayName: 'First');
      await Store.instance.putSamples('JCV8B 44300D', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 9), 61)]);

      await Collecting.instance.select('p-bbb', displayName: 'Second');
      await Store.instance.putSamples('JCV8B 44300D', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 10), 64)]);

      final all = await rows();
      expect(all.length, 2);
      final byTime = {for (final r in all) r['at'] as int: r['owner']};
      final t9 = DateTime(2026, 9, 14, 9).toUtc().millisecondsSinceEpoch;
      final t10 = DateTime(2026, 9, 14, 10).toUtc().millisecondsSinceEpoch;
      expect(byTime[t9], 'p-aaa');
      expect(byTime[t10], 'p-bbb');
    });

    test('re-reading a band does NOT re-attribute rows to whoever is now set',
        () async {
      // The failure this prevents, observed on the live database: a
      // participant's band was synced by an admin collecting for her and
      // correctly stamped. The next day the same phone, signed in as its own
      // user with no participant chosen, reconnected to that band and
      // re-read its history. Every row was re-stamped to nobody and
      // re-uploaded under the operator — 17,423 of her readings landed in
      // his profile.
      await Collecting.instance.select('p-abirami', displayName: 'Abirami');
      await Store.instance.putSamples('JCV5 BE8D18', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 9), 61)]);
      expect((await rows()).single['owner'], 'p-abirami');
      await Store.instance.markSamplesSynced(await rows());

      // Now nobody is selected, and the same history is pulled again.
      await Collecting.instance.clear();
      await Store.instance.putSamples('JCV5 BE8D18', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 9), 61)]);

      final all = await Store.instance.unsyncedSamples();
      expect(all, isEmpty,
          reason: 'an unchanged re-read must not re-queue the row');

      final d = await Store.instance.db;
      final stored = await d.query('samples');
      expect(stored.single['owner'], 'p-abirami',
          reason: 'ownership is decided when a reading is first stored and '
              'never changes; a re-read cannot hand it to someone else');
    });

    test('a genuinely new reading still gets the current owner', () async {
      await Collecting.instance.select('p-abirami', displayName: 'Abirami');
      await Store.instance.putSamples('JCV5 BE8D18', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 9), 61)]);
      await Collecting.instance.select('p-gaj', displayName: 'Gajendran');
      await Store.instance.putSamples('JCV5 BE8D18', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 10), 64)]);

      final d = await Store.instance.db;
      final stored = await d.query('samples', orderBy: 'at ASC');
      expect(stored.first['owner'], 'p-abirami');
      expect(stored.last['owner'], 'p-gaj');
    });

    test('re-sending everything keeps each row with its own person', () async {
      await Collecting.instance.select('p-aaa', displayName: 'First');
      await Store.instance.putSamples('JCV8B 44300D', 'heart_rate',
          [Sample(DateTime(2026, 9, 14, 9), 61)]);
      await Store.instance.markSamplesSynced(await rows());
      await Collecting.instance.select('p-bbb', displayName: 'Second');

      // "Re-send all" re-queues everything. It must not re-file it.
      await Store.instance.resetSyncState();
      expect((await rows()).single['owner'], 'p-aaa');
    });
  });

  test('signing out forgets who was being collected for', () async {
    await Collecting.instance.select('p-123', displayName: 'Gajendran');
    await Session.instance.signOut();
    expect(Collecting.instance.active, isFalse,
        reason: 'a selection that survived sign-out would stamp the next '
            'person\'s readings with a stranger\'s profile id, and they '
            'would have no reason to look');
  });
}
