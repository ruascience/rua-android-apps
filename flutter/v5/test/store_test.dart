import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aurav5/data/store.dart';

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
}
