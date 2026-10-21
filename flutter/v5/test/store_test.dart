import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aurav5/data/store.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// Guards the offline path: a phone holding a month of history must show it
/// while disconnected. Rendering "No data yet" over stored data reads as data
/// loss, which is the worst thing a health app can imply.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await Store.instance.resetForTest();
  });

  test('lastSeenDevice is null on an empty store', () async {
    expect(await Store.instance.lastSeenDevice(), isNull);
  });

  test('lastSeenDevice finds the only device with data', () async {
    await Store.instance.putSamples('JCV5 6C6BB3', 'heart_rate',
        [Sample(DateTime(2026, 8, 27, 12), 71)]);
    expect(await Store.instance.lastSeenDevice(), 'JCV5 6C6BB3');
  });

  test('with several bands it picks the most RECENTLY seen', () async {
    await Store.instance.putSamples('JCV8B 44300D', 'heart_rate',
        [Sample(DateTime(2026, 8, 20, 9), 60)]);
    await Store.instance.putSamples('JCV5 6C6BB3', 'heart_rate',
        [Sample(DateTime(2026, 8, 27, 12), 71)]);
    expect(await Store.instance.lastSeenDevice(), 'JCV5 6C6BB3',
        reason: 'the band you used last is the one to show offline');
  });

  test('recency is by newest sample, not by insertion order', () async {
    // Insert the OLDER band second: an ORDER BY rowid would get this wrong.
    await Store.instance.putSamples('JCV5 6C6BB3', 'heart_rate',
        [Sample(DateTime(2026, 8, 27, 12), 71)]);
    await Store.instance.putSamples('JCV8B 44300D', 'heart_rate',
        [Sample(DateTime(2026, 8, 20, 9), 60)]);
    expect(await Store.instance.lastSeenDevice(), 'JCV5 6C6BB3');
  });

  test('stored samples are readable without any connection', () async {
    const dev = 'JCV5 6C6BB3';
    await Store.instance.putSamples(dev, 'heart_rate', [
      for (var i = 0; i < 10; i++)
        Sample(DateTime(2026, 8, 27, 12, 0, i * 5), (70 + i).toDouble())
    ]);
    await Store.instance.putSamples(
        dev, 'spo2', [Sample(DateTime(2026, 8, 27, 13, 1, 41), 98)]);

    final found = await Store.instance.lastSeenDevice();
    expect(found, dev);
    final hr = await Store.instance
        .read(found!, 'heart_rate', since: DateTime(2026, 8, 1));
    final spo2 = await Store.instance
        .read(found, 'spo2', since: DateTime(2026, 8, 1));
    expect(hr.length, 10);
    expect(spo2.single.value, 98);
  });

  group('a reading must name its band', () {
    test('an empty device name is refused, loudly', () async {
      // Rows stored under '' can never be uploaded — the server requires the
      // name — and two phones stored five days of them before anyone saw.
      expect(
          () => Store.instance
              .putSamples('', 'heart_rate', [Sample(DateTime(2026, 10, 15), 70)]),
          throwsArgumentError);
      expect(
          () => Store.instance.putSleepSegments('', [
                j.SleepSegment(DateTime(2026, 10, 15), 30, const [1, 2])
              ]),
          throwsArgumentError);
      expect(await Store.instance.lastSeenDevice(), isNull);
    });

    test('rows already stored under no name are re-filed and re-queued',
        () async {
      const name = 'JCV5 6C6BB3';
      final d = await Store.instance.db;
      // What a phone that hit the bug holds: blank device, marked synced
      // because the server's 400 was taken as final.
      for (var i = 0; i < 3; i++) {
        await d.rawInsert(
            'INSERT INTO samples(device, metric, at, value, owner, synced) '
            "VALUES ('', 'heart_rate', ?, ?, NULL, 1)",
            [DateTime(2026, 10, 15, 10, i).millisecondsSinceEpoch, 70 + i]);
      }
      // A daily total read first under the real name, then again — later,
      // higher — under the blank one. The later read must win.
      final day = DateTime(2026, 10, 15).millisecondsSinceEpoch;
      await Store.instance
          .putSamples(name, 'steps', [Sample(DateTime(2026, 10, 15), 1200)]);
      await Store.instance.markSamplesSynced([
        {'device': name, 'metric': 'steps', 'at': day}
      ]);
      await d.rawInsert(
          'INSERT INTO samples(device, metric, at, value, owner, synced) '
          "VALUES ('', 'steps', ?, 4800, NULL, 1)",
          [day]);
      await d.rawInsert(
          'INSERT INTO sleep_segments(device, start, minutes, stages, owner, synced) '
          "VALUES ('', ?, 420, '1,2,3', NULL, 1)",
          [DateTime(2026, 10, 14, 23).millisecondsSinceEpoch]);

      expect(await Store.instance.reassignBlankDevice(name), 5);

      final blank = await d
          .rawQuery("SELECT COUNT(*) AS n FROM samples WHERE device = ''");
      expect(blank.first['n'], 0);
      final blankSleep = await d.rawQuery(
          "SELECT COUNT(*) AS n FROM sleep_segments WHERE device = ''");
      expect(blankSleep.first['n'], 0);
      expect(await Store.instance.pendingCount(), 5,
          reason: 'all re-filed rows are queued for upload again');
      final steps = await d.query('samples',
          where: 'device = ? AND metric = ?', whereArgs: [name, 'steps']);
      expect(steps.single['value'], 4800.0,
          reason: 'the later read of the day replaces the earlier one');
      expect(steps.single['synced'], 0);

      expect(await Store.instance.reassignBlankDevice(name), 0,
          reason: 'idempotent: safe to run on every launch');
      expect(await Store.instance.reassignBlankDevice(''), 0,
          reason: 'no name to give them is not a reason to touch anything');
    });
  });
}
