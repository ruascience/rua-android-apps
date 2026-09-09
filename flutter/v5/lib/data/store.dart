/// Local sample store.
///
/// The band holds ~30 days and overwrites; this keeps everything we ever
/// pulled, so a sync is additive rather than a snapshot. All timestamps are
/// stored as UTC milliseconds — the band reports local wall-clock time with
/// no zone, so it is converted at the boundary rather than stored ambiguously.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../protocol/jstyle.dart' as j;
// sqflite_ffi re-exports the sqflite API and adds the desktop factory.
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Sample {
  final DateTime at;
  final double value;
  const Sample(this.at, this.value);
}

class Store {
  Store._();
  static final Store instance = Store._();

  Database? _db;

  /// Bumped on every write, and broadcast.
  ///
  /// Pages reload when a band CONNECTS, but the sync that actually fills the
  /// database happens afterwards. Without this signal a page computes its
  /// metrics from whatever was there at connect time — which showed a resting
  /// heart rate of 84 bpm from a handful of daytime samples when the real
  /// answer, from 3852 overnight ones, was 40.
  int revision = 0;
  final _changes = StreamController<int>.broadcast();
  Stream<int> get changes => _changes.stream;
  void _bump() {
    revision++;
    _changes.add(revision);
  }

  Future<Database> get db async => _db ??= await _open();

  /// Point the store at a fresh in-memory database. Tests only.
  ///
  /// Without this every test shares one on-disk file and they contaminate
  /// each other — which matters here because the offline fallback is defined
  /// by *which* device has the newest data.
  @visibleForTesting
  Future<void> resetForTest() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await _db?.close();
    _db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 5, onCreate: _create));
    revision = 0;
  }

  Future<Database> _open() async {
    // sqflite has no native macOS/Linux desktop implementation; the ffi
    // backend supplies one. Android/iOS use the built-in.
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'jcvital.db');
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onUpgrade: (d, from, to) async {
          // Each step is additive and idempotent: existing sample data is
          // never rewritten, so an upgrade cannot lose a month of history.
          if (from < 2) await _createSleep(d);
          if (from < 3) await _createProfile(d);
          // v4 marks rows for cloud sync. Existing rows default to 0 =
          // unsynced, which is deliberate: everything already on the phone
          // gets pushed once, so the server converges on the full history
          // rather than only on what arrives after today.
          if (from < 4) await _addSyncColumns(d);
          // v5 names the person: the id their data is filed under on the
          // server, and two contact details. Additive like every step above
          // it, and for the same reason — the phone this ships to is holding
          // 55,779 samples and a profile that took a first-run sheet to
          // collect.
          if (from < 5) await _addProfileIdentityColumns(d);
        },
        onCreate: _create,
      ),
    );
  }

  /// The v2 schema. Shared by the on-disk open and by resetForTest, so a
  /// test database can never drift from the real one.
  static Future<void> _create(Database d, int _) async {
          // A sample is identified by (device, metric, time): re-syncing the
          // same day must not duplicate rows, so the primary key does the
          // de-duplication instead of a read-modify-write.
          await d.execute('''
            CREATE TABLE samples (
              device TEXT NOT NULL,
              metric TEXT NOT NULL,
              at     INTEGER NOT NULL,
              value  REAL NOT NULL,
              PRIMARY KEY (device, metric, at)
            )
          ''');
          await d.execute(
              'CREATE INDEX idx_samples_lookup ON samples(device, metric, at)');
          await d.execute('''
            CREATE TABLE raw_frames (
              id       INTEGER PRIMARY KEY AUTOINCREMENT,
              device   TEXT NOT NULL,
              at       INTEGER NOT NULL,
              direction TEXT NOT NULL,
              opcode   INTEGER,
              hex      TEXT NOT NULL
            )
          ''');
          await d.execute(
              'CREATE INDEX idx_raw_at ON raw_frames(device, at)');
          await _createSleep(d);
          await _createProfile(d);
          await _addSyncColumns(d);
          await _addProfileIdentityColumns(d);
          }

  /// Add the cloud-sync bookkeeping.
  ///
  /// A flag on the row rather than a separate outbox table. An outbox has to
  /// be kept in step with the data it mirrors, and any bug in that pairing
  /// loses rows silently; a column cannot drift from the row it is on.
  ///
  /// Wrapped because ALTER TABLE throws if the column is already there, and
  /// on a fresh install _create has just added it.
  static Future<void> _addSyncColumns(Database d) async {
    for (final t in ['samples', 'sleep_segments']) {
      try {
        await d.execute(
            'ALTER TABLE $t ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
      } catch (_) {
        // Already present.
      }
    }
    // Partial index: the pusher only ever asks for unsynced rows, and once
    // the backlog is gone this index stays tiny however large the table is.
    try {
      await d.execute('CREATE INDEX IF NOT EXISTS idx_samples_unsynced '
          'ON samples(synced) WHERE synced = 0');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_sleep_unsynced '
          'ON sleep_segments(synced) WHERE synced = 0');
    } catch (_) {
      // Index is an optimisation, never a correctness requirement.
    }
  }

  /// v5: who the profile IS, as distinct from what it says.
  ///
  /// `profile_id` is the `_id` the server files this person under — a UUID,
  /// either adopted from the server or minted here, and then never changed.
  /// It lives on the row rather than in SharedPreferences deliberately: the
  /// band id in preferences is connection scaffolding the app rewrites on
  /// every connect, while this is the key the person's whole history hangs
  /// off. An id that came back different after a preferences wipe would not
  /// be the same person on the server, it would be a SECOND one.
  ///
  /// `phone` and `email` are nullable with no default because NULL is the
  /// honest answer for every row that already exists: nobody was ever asked.
  ///
  /// Wrapped for the same reason as [_addSyncColumns]: ALTER TABLE throws
  /// when the column is already there, and on a fresh install _create has
  /// just added it. Nothing here rewrites a row.
  static Future<void> _addProfileIdentityColumns(Database d) async {
    for (final c in ['profile_id TEXT', 'phone TEXT', 'email TEXT']) {
      try {
        await d.execute('ALTER TABLE profile ADD COLUMN $c');
      } catch (_) {
        // Already present.
      }
    }
  }

  /// Run the v5 step against a database of the test's own making.
  ///
  /// The upgrade path is otherwise unreachable from a test: [resetForTest]
  /// opens at the CURRENT version, so onUpgrade never fires and the one
  /// property worth pinning — that a real row survives the migration
  /// untouched — would never be exercised until the user's phone ran it.
  @visibleForTesting
  static Future<void> upgradeProfileIdentityForTest(Database d) =>
      _addProfileIdentityColumns(d);

  // ------------------------------------------------------- cloud sync

  /// Rows the server has not confirmed yet, oldest first.
  Future<List<Map<String, Object?>>> unsyncedSamples({int limit = 500}) async {
    final d = await db;
    return d.query('samples',
        where: 'synced = 0', orderBy: 'at ASC', limit: limit);
  }

  Future<List<Map<String, Object?>>> unsyncedSleep({int limit = 200}) async {
    final d = await db;
    return d.query('sleep_segments',
        where: 'synced = 0', orderBy: 'start ASC', limit: limit);
  }

  /// Mark exactly the rows that were accepted.
  ///
  /// Keyed on the same natural key the server uses, so a row written while
  /// the batch was in flight is not marked synced by mistake — it simply is
  /// not in this list and goes out with the next batch.
  Future<void> markSamplesSynced(Iterable<Map<String, Object?>> rows) async {
    final d = await db;
    final batch = d.batch();
    for (final r in rows) {
      batch.update('samples', {'synced': 1},
          where: 'device = ? AND metric = ? AND at = ?',
          whereArgs: [r['device'], r['metric'], r['at']]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> markSleepSynced(Iterable<Map<String, Object?>> rows) async {
    final d = await db;
    final batch = d.batch();
    for (final r in rows) {
      batch.update('sleep_segments', {'synced': 1},
          where: 'device = ? AND start = ?',
          whereArgs: [r['device'], r['start']]);
    }
    await batch.commit(noResult: true);
  }

  /// How much is still waiting to go up. Shown in the UI, so a stalled sync
  /// is visible rather than something the user has to take on trust.
  Future<int> pendingCount() async {
    final d = await db;
    int count(List<Map<String, Object?>> rows) =>
        rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);
    final a = count(
        await d.rawQuery('SELECT COUNT(*) AS n FROM samples WHERE synced = 0'));
    final b = count(await d
        .rawQuery('SELECT COUNT(*) AS n FROM sleep_segments WHERE synced = 0'));
    return a + b;
  }

  /// Send everything again. Used after pointing the app at a different
  /// server, where the new one holds none of it.
  Future<void> resetSyncState() async {
    final d = await db;
    await d.update('samples', {'synced': 0});
    await d.update('sleep_segments', {'synced': 0});
    _bump();
  }

  static Future<void> _createSleep(Database d) async {
    // One row per 0x53 segment. Keyed by (device, start) so re-syncing the
    // same night replaces rather than duplicates.
    await d.execute("""
      CREATE TABLE IF NOT EXISTS sleep_segments (
        device  TEXT NOT NULL,
        start   INTEGER NOT NULL,
        minutes INTEGER NOT NULL,
        stages  TEXT NOT NULL,
        PRIMARY KEY (device, start)
      )
    """);
  }

  /// The user's own details, collected once on first run.
  ///
  /// One row, id pinned to 1. A CHECK constraint rather than convention: a
  /// second profile row would silently give every reader a different answer
  /// depending on row order, and age feeds VO2max, strain and BioAge.
  ///
  /// Period starts live in their own table rather than as a joined string —
  /// they are a growing list, and a delimiter in a date column is how you end
  /// up unable to store a locale that uses it.
  static Future<void> _createProfile(Database d) async {
    await d.execute("""
      CREATE TABLE IF NOT EXISTS profile (
        id        INTEGER PRIMARY KEY CHECK (id = 1),
        name      TEXT    NOT NULL DEFAULT '',
        age       INTEGER NOT NULL,
        sex       INTEGER NOT NULL,
        height_cm INTEGER NOT NULL,
        weight_kg REAL    NOT NULL,
        onboarded INTEGER NOT NULL DEFAULT 0
      )
    """);
    await d.execute("""
      CREATE TABLE IF NOT EXISTS period_starts (
        day TEXT PRIMARY KEY
      )
    """);
  }

  Future<Map<String, Object?>?> readProfile() async {
    final d = await db;
    final rows = await d.query('profile', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// ⚠ Every column the row has must be passed on every call.
  ///
  /// This is an INSERT OR REPLACE of the whole row, not an update of the
  /// fields it mentions — a value left out is not left alone, it is written
  /// as NULL. That is why [profileId], [phone] and [email] are named here at
  /// all rather than being given their own writer: the profile's only caller
  /// holds all of them, and a second writer that knew about three columns and
  /// not the other six is how the id this whole change exists to keep stable
  /// would get erased by an edit to somebody's weight.
  Future<void> writeProfile({
    required String name,
    required int age,
    required int sex,
    required int heightCm,
    required double weightKg,
    required bool onboarded,
    String? profileId,
    String? phone,
    String? email,
  }) async {
    final d = await db;
    await d.insert(
      'profile',
      {
        'id': 1,
        'name': name,
        'age': age,
        'sex': sex,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'onboarded': onboarded ? 1 : 0,
        'profile_id': profileId,
        'phone': phone,
        'email': email,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _bump();
  }

  Future<List<DateTime>> readPeriodStarts() async {
    final d = await db;
    final rows = await d.query('period_starts', orderBy: 'day');
    return [
      for (final r in rows)
        if (DateTime.tryParse(r['day'] as String) != null)
          DateTime.parse(r['day'] as String)
    ];
  }

  Future<void> writePeriodStarts(Iterable<DateTime> days) async {
    final d = await db;
    final batch = d.batch();
    batch.delete('period_starts');
    for (final day in days) {
      batch.insert(
        'period_starts',
        {'day': DateTime(day.year, day.month, day.day).toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _bump();
  }

  Future<void> putSleepSegments(
      String device, Iterable<j.SleepSegment> segs) async {
    final d = await db;
    final batch = d.batch();
    for (final s in segs) {
      batch.insert(
        'sleep_segments',
        {
          'device': device,
          'start': s.start.toUtc().millisecondsSinceEpoch,
          'minutes': s.minutes,
          'stages': s.stages.join(','),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _bump();
  }

  Future<List<j.SleepSegment>> readSleepSegments(String device,
      {DateTime? since}) async {
    final d = await db;
    final rows = await d.query(
      'sleep_segments',
      where: since == null ? 'device = ?' : 'device = ? AND start >= ?',
      whereArgs: since == null
          ? [device]
          : [device, since.toUtc().millisecondsSinceEpoch],
      orderBy: 'start ASC',
    );
    return rows.map((r) {
      // tryParse, not parse: this is the one place a stored row is turned
      // back into numbers, and a single malformed cell would otherwise throw
      // out of a DB read and take the Sleep page down with it.
      final stages = ((r['stages'] as String?) ?? '')
          .split(',')
          .map((e) => int.tryParse(e.trim()))
          .whereType<int>()
          .toList();
      return j.SleepSegment(
        DateTime.fromMillisecondsSinceEpoch(r['start'] as int, isUtc: true)
            .toLocal(),
        r['minutes'] as int,
        stages,
      );
    }).toList();
  }

  Future<void> putSamples(
      String device, String metric, Iterable<Sample> samples) async {
    final d = await db;
    final batch = d.batch();
    for (final s in samples) {
      batch.insert(
        'samples',
        {
          'device': device,
          'metric': metric,
          'at': s.at.toUtc().millisecondsSinceEpoch,
          'value': s.value,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    _bump();
  }

  Future<List<Sample>> read(String device, String metric,
      {DateTime? since, int limit = 5000}) async {
    final d = await db;
    final rows = await d.query(
      'samples',
      where: since == null
          ? 'device = ? AND metric = ?'
          : 'device = ? AND metric = ? AND at >= ?',
      whereArgs: since == null
          ? [device, metric]
          : [device, metric, since.toUtc().millisecondsSinceEpoch],
      // Take the NEWEST rows, then restore chronological order.
      //
      // This was 'at ASC' with the same limit, which silently returned the
      // OLDEST 5000 and dropped everything newer — with 6963 heart-rate
      // samples already stored, the app was showing data that never advanced.
      // Every caller and every analytic downstream (night pooling, day
      // bucketing, sparklines, `data.last`) assumes ascending order, so the
      // reverse is required, not cosmetic.
      orderBy: 'at DESC',
      limit: limit,
    );
    return rows.reversed
        .map((r) => Sample(
              DateTime.fromMillisecondsSinceEpoch(r['at'] as int, isUtc: true)
                  .toLocal(),
              (r['value'] as num).toDouble(),
            ))
        .toList();
  }

  /// True when [read] for this metric/window hit its cap and truncated.
  ///
  /// Callers that show a total should ask, rather than printing the returned
  /// length as if it were the real count.
  Future<bool> wasTruncated(String device, String metric,
      {DateTime? since, int limit = 5000}) async {
    final d = await db;
    final r = await d.rawQuery(
      since == null
          ? 'SELECT COUNT(*) c FROM samples WHERE device = ? AND metric = ?'
          : 'SELECT COUNT(*) c FROM samples WHERE device = ? AND metric = ? '
              'AND at >= ?',
      since == null
          ? [device, metric]
          : [device, metric, since.toUtc().millisecondsSinceEpoch],
    );
    return ((r.first['c'] as int?) ?? 0) > limit;
  }

  /// The device with the most recent sample, or null if the store is empty.
  ///
  /// Exists so the app can show what it already has while disconnected. The
  /// pages key their reads on the live connection's device name, which is
  /// empty when offline — without a fallback, a phone holding a month of
  /// history renders "No data yet", which reads as data loss.
  ///
  /// Derived from the data rather than from saved preferences deliberately:
  /// it stays correct if the profile is cleared, and it cannot point at a
  /// device that has nothing stored.
  Future<String?> lastSeenDevice() async {
    // Bounded on purpose. This runs on the UI's first frame, and a platform
    // channel with no plugin behind it (widget tests, an unsupported host)
    // never completes rather than failing — which would leave the page
    // spinning forever instead of showing its empty state.
    final Database d;
    try {
      d = await db.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
    final rows = await d.rawQuery(
        'SELECT device FROM samples GROUP BY device ORDER BY MAX(at) DESC '
        'LIMIT 1');
    if (rows.isEmpty) return null;
    return rows.first['device'] as String?;
  }

  /// Every band this install holds data for, newest first — or `null` when
  /// the question could not be asked.
  ///
  /// The tri-state is the point. [lastSeenDevice] folds "no history" and "the
  /// database did not answer" into one `null`, which is right for a page
  /// choosing whether to draw an empty state and wrong for the caller here:
  /// CloudSync uses this to decide which names to offer the server when it is
  /// trying to ADOPT an existing profile, and an empty list read off a
  /// timeout would silently narrow the search that prevents a duplicate
  /// person.
  ///
  /// Plural because this phone has two bands — 34,373 samples came from
  /// `JCV5 6C6BB3` and 20,906 from `JCV5 BE8D18` — and the server's profile
  /// is filed under whichever one happened to be connected first.
  Future<List<String>?> knownDevices() async {
    final Database d;
    try {
      d = await db.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
    try {
      final rows = await d.rawQuery(
          'SELECT device FROM samples GROUP BY device ORDER BY MAX(at) DESC');
      return [
        for (final r in rows)
          if (r['device'] is String && (r['device'] as String).isNotEmpty)
            r['device'] as String,
      ];
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, int>> counts(String device) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT metric, COUNT(*) n FROM samples WHERE device = ? GROUP BY metric',
        [device]);
    return {for (final r in rows) r['metric'] as String: r['n'] as int};
  }

  /// Keep every frame we send or receive. Protocol work is archaeology: the
  /// packet that makes sense of an opcode is usually one captured before we
  /// knew what to look for.
  Future<void> putFrame(String device, String direction, int? opcode,
      String hex) async {
    final d = await db;
    await d.insert('raw_frames', {
      'device': device,
      'at': DateTime.now().toUtc().millisecondsSinceEpoch,
      'direction': direction,
      'opcode': opcode,
      'hex': hex,
    });
  }

  Future<List<Map<String, Object?>>> recentFrames(String device,
      {int limit = 500}) async {
    final d = await db;
    return d.query('raw_frames',
        where: 'device = ?',
        whereArgs: [device],
        orderBy: 'at DESC',
        limit: limit);
  }

  Future<String> exportCsv(String device) async {
    final d = await db;
    final rows = await d.query('samples',
        where: 'device = ?', whereArgs: [device], orderBy: 'metric, at');
    final b = StringBuffer('metric,timestamp_local,value\n');
    for (final r in rows) {
      final t = DateTime.fromMillisecondsSinceEpoch(r['at'] as int, isUtc: true)
          .toLocal();
      b.writeln('${r['metric']},${t.toIso8601String()},${r['value']}');
    }
    return b.toString();
  }
}
