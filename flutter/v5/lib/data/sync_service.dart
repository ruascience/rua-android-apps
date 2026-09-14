/// Pulling the band's history, and sampling it live.
///
/// This used to live inside DevicePage, which meant a sync could only happen
/// while somebody was looking at that screen. Automatic reconnection needs the
/// same work done with no UI attached — a reconnect without a sync is half a
/// fix, since the reason the drop mattered is the data logged while the link
/// was down.
library;

import 'dart:async';

import '../ble/band_link.dart';
import '../protocol/jstyle.dart' as j;
import 'store.dart';

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final BandLink _link = BandLink.instance;

  /// One sync at a time.
  ///
  /// Both the Sync button and the reconnect handler call this, and they can
  /// fire together — a reconnect while the user is already syncing. Two
  /// concurrent pulls interleave their history frames on one notify
  /// characteristic, and the paging cursor is per-opcode, so the records come
  /// back attributed to the wrong stream.
  bool _busy = false;
  bool get busy => _busy;

  /// What the sync is doing right now, in the user's words.
  ///
  /// syncAll() walks every history opcode the band answers, pulling and
  /// decoding each in turn, and that can take minutes. Reporting only "busy"
  /// gave one indeterminate bar for the whole run: no step, no proportion, and
  /// no way to tell a slow sync from a stuck one.
  String phase = '';

  /// Rows written to SQLite during this run, so the number moves even while a
  /// single slow opcode is being pulled.
  int storedThisRun = 0;

  /// How far the band's own calendar is from this phone's, in days.
  ///
  /// Null until a sync has read the daily totals. Non-zero means every
  /// reading pulled off this band is stamped with a date that is wrong by
  /// that much — see where it is computed for why nothing corrects it.
  int? clockDriftDays;

  /// The last failure, if the run ended in one. Cleared when a run starts.
  String lastError = '';

  void _report(String p) {
    phase = p;
    _changes.add(null);
  }

  /// Emits whenever a sync starts or finishes.
  ///
  /// Added because the startup auto-connect now kicks off a sync on its own:
  /// for the ~40 s that takes, a tap on "Sync history" hit the guard below
  /// and returned instantly, with no spinner, no message and nothing in the
  /// log. Indistinguishable from a dead button.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> syncAll() async {
    if (_busy || !_link.connected) return;
    _busy = true;
    storedThisRun = 0;
    lastError = '';
    _report('checking battery');
    try {
      final dev = _link.deviceName;
      await _link.readBattery();

      // Steps / distance / calories: opcode 0x51, one record per day.
      _report('daily activity');
      final days = await _link.readDailyTotals();
      if (days.isNotEmpty) {
        await Store.instance.putSamples(dev, 'steps',
            [for (final d in days) Sample(d.day, d.steps.toDouble())]);
        await Store.instance.putSamples(
            dev, 'distance', [for (final d in days) Sample(d.day, d.km)]);
        await Store.instance.putSamples(
            dev, 'calories', [for (final d in days) Sample(d.day, d.kcal)]);
        await Store.instance.putSamples(dev, 'active_minutes', [
          for (final d in days) Sample(d.day, d.active.inMinutes.toDouble())
        ]);
        _link.log.add('stored ${days.length} day(s) of activity');

        // The band's clock, checked against the phone's.
        //
        // Nothing ever sets the band's clock — `set_time` (0x01) exists in
        // the opcode table and this app has never sent it — so every record
        // is stamped by whatever the band believes the date is. A band whose
        // clock was wrong, or which reset after a flat battery, produces a
        // complete and plausible dataset filed under the wrong dates, and
        // the record parser accepts any well-formed date. That is invisible
        // on a 14-day view: the readings simply are not there.
        //
        // 0x51 writes one record per day, so the newest one IS the band's
        // idea of today. Free, and read-only.
        final newest = days.map((d) => d.day).reduce((a, b) => a.isAfter(b) ? a : b);
        final today = DateTime.now();
        final drift = DateTime(today.year, today.month, today.day)
            .difference(DateTime(newest.year, newest.month, newest.day))
            .inDays;
        clockDriftDays = drift;
        if (drift.abs() > 1) {
          _link.log.add('⚠ band clock looks wrong: its newest day is '
              '${newest.year}-${newest.month.toString().padLeft(2, '0')}-'
              '${newest.day.toString().padLeft(2, '0')}, '
              '${drift > 0 ? '$drift day(s) behind' : '${-drift} day(s) ahead of'} '
              'this phone — stored readings will carry those dates');
        }
      } else {
        // Said out loud. An empty 0x51 pull used to log nothing at all, and
        // the Today screen then drew "Steps 0 / 10,000" — which reads as a
        // sedentary day rather than as a day with no record.
        _link.log.add('daily activity: band returned no records');
      }

    final historyOps =
        j.ops.where((o) => o.safe && o.name.startsWith('hist_')).toList();
      for (final (i, op) in historyOps.indexed) {
        // Named by what it holds rather than by opcode: "hist_heart_rate"
        // means nothing to the person waiting, and the number is what tells
        // them the run is progressing rather than hung.
        _report('${op.name.replaceFirst('hist_', '').replaceAll('_', ' ')} '
            '(${i + 1} of ${historyOps.length})');
        final records = await _link.pullHistory(op.code);
        if (records.isEmpty) continue;

        final bucket = <String, List<Sample>>{};
        final sleepSegs = <j.SleepSegment>[];
        void add(String metric, DateTime? t, num? v) {
          if (t == null || v == null) return;
          (bucket[metric] ??= []).add(Sample(t, v.toDouble()));
        }

        for (final r in records) {
          // Every arm below is reachable only if this build's opcode table
          // lists that opcode as a hist_ entry — the loop above is what
          // decides. Arms for opcodes another band keeps its data under are
          // kept here so all three apps share one decoder.
          switch (op.code) {
            case j.opHeartRateOnce:
              // Spot heart rate: one sample per record, not 0x54's 15 slots.
              final o = j.parseHeartRateOnce(r);
              add('heart_rate', o.time, o.bpm);
            case j.opHistHeartRate:
              for (final e in j.hrSamplesTimed(r)) {
                add('heart_rate', e.key, e.value);
              }
            case j.opTemperatureHistory:
              final t62 = j.parseTempRecord(r);
              add('temperature', t62.time, t62.celsius);
            case j.opHistTemperature:
              final t = j.parseTempRecord(r);
              add('temperature', t.time, t.celsius);
            case j.opHistSpo2:
            case j.opHistSpo2Alt:
              final s = j.parseSpo2Record(r);
              add('spo2', s.time, s.percent);
            case j.opHistSleep:
              final seg = j.parseSleepRecord(r);
              if (seg != null) sleepSegs.add(seg);
            case j.opHistHrv:
              final h = j.parseHrvRecord(r);
              if (h != null) {
                add('hrv', h.time, h.hrvMs);
                add('stress', h.time, h.stress);
                // A zero in a scheduled record means NOBODY ASKED, not a
                // reading of zero. Storing them would put 0 bpm in the
                // history and drag every average down.
                if (h.heartRate > 0) add('heart_rate', h.time, h.heartRate);
                if (h.systolic > 0) add('systolic', h.time, h.systolic);
                if (h.diastolic > 0) add('diastolic', h.time, h.diastolic);
              }
          }
        }

        if (sleepSegs.isNotEmpty) {
          await Store.instance.putSleepSegments(dev, sleepSegs);
          storedThisRun += sleepSegs.length;
          _link.log.add('stored ${sleepSegs.length} sleep segments');
        }
        for (final e in bucket.entries) {
          await Store.instance.putSamples(dev, e.key, e.value);
          storedThisRun += e.value.length;
          _link.log.add('stored ${e.value.length} ${e.key}');
        }
        _changes.add(null);
      }
      // Retention, after the pull rather than before it: a sync is the only
      // moment new rows arrive, so it is the only moment the total can have
      // grown. Nothing expired at all before this, and nothing displays rows
      // this old either — every page reads a window of days and the reads are
      // capped — so the storage was pure cost.
      //
      // A year and a bit, so that "this time last year" still works and a
      // yearly comparison does not fall off the end of the window it needs.
      final pruned =
          await Store.instance.pruneSamplesOlderThan(const Duration(days: 400));
      if (pruned > 0) _link.log.add('pruned $pruned samples over 400 days old');
    } catch (e) {
      // Recorded rather than swallowed. A sync that failed halfway used to be
      // indistinguishable from one that finished: the spinner stopped either
      // way. Rethrown so the caller can also say so.
      lastError = '$e';
      _link.log.add('sync failed: $e');
      rethrow;
    } finally {
      _busy = false;
      phase = '';
      _changes.add(null);
    }
  }
}

/// Drives an on-demand measurement on a fixed interval and stores the result.
///
/// ⚠ At the current five-minute interval there is a cheaper way to get the
/// same numbers, and it is worth knowing about before using this.
///
/// The band's OWN background logging (0x2A) also bottoms out at 5 minutes.
/// Where this differs from that is not resolution — it is who does the work:
///
///   * 0x2A: the BAND samples and logs on its own. Costs almost nothing,
///     keeps running with the phone out of range, and survives a dropped
///     link. Read it back later with a sync.
///   * this: the APP asks over BLE each interval with 0x28. Only runs while
///     connected, and each cycle keeps the optical front end lit for ~30 s.
///
/// So at 5 minutes, 0x2A does the same job better. This earns its place when
/// a reading is wanted immediately rather than on the next sync, or at an
/// interval the band's own scheduler cannot reach — under 5 minutes, where
/// 0x2A simply cannot go.
///
/// Blood pressure is deliberately NOT stored from these cycles. The band
/// reports it and it decodes cleanly, which is exactly the problem: no wrist
/// optical sensor can measure it without cuff calibration.
class PeriodicSampler {
  PeriodicSampler._();
  static final PeriodicSampler instance = PeriodicSampler._();

  final BandLink _link = BandLink.instance;

  /// How often a cycle STARTS. A cycle that overruns is not stacked on top of
  /// the next one — see [_running].
  ///
  /// Five minutes. Below this the band's own 0x2A scheduler cannot follow, so
  /// app-driven sampling is the only option; at or above it, 0x2A is the
  /// better tool (see the class doc).
  static const period = Duration(minutes: 5);

  /// How long to wait for the sensor to converge before giving up on a cycle.
  static const convergeLimit = Duration(seconds: 40);

  Timer? _timer;
  bool _running = false;
  bool get enabled => _timer != null;

  DateTime? lastSampleAt;
  String lastResult = '';

  void start() {
    if (_timer != null) return;
    _link.log.add('periodic sampling: on (every ${period.inMinutes} min)');
    _timer = Timer.periodic(period, (_) => _tick());
    unawaited(_tick());
  }

  void stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _link.log.add('periodic sampling: off');
  }

  Future<void> _tick() async {
    // Skip rather than queue. A sync or a manual measurement owns the same
    // single command channel — overlapping them interleaves frames on one
    // notify characteristic and misattributes the replies. A skipped tick is
    // picked up by the next one rather than queued behind a long sync.
    if (_running || !_link.connected || SyncService.instance.busy) return;
    _running = true;
    try {
      final start = _link.replies.length;
      await _link.sendOp(j.opMeasure,
          payload: j.measurePayload(on: true),
          wait: const Duration(milliseconds: 600));

      // The band acks immediately with an all-zero frame and sends real
      // values ~30 s later. Taking the ack for the answer cancels the
      // measurement every time.
      j.LiveReading? got;
      double? tempC;
      final deadline = DateTime.now().add(convergeLimit);
      while (DateTime.now().isBefore(deadline) && got == null) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!_link.connected) break;
        for (final r in _link.replies.skip(start)) {
          final c = j.parseRealtimeTemperature(r.data);
          if (c != null) tempC = c;
          if (r.opcode != j.opMeasure) continue;
          final p = j.parseOnDemand(r.data);
          if (p != null && p.hasAnything) got = p;
        }
      }

      if (_link.connected) {
        await _link.sendOp(j.opMeasure, payload: j.measurePayload(on: false));
      }

      final now = DateTime.now();
      final dev = _link.deviceName;
      final bits = <String>[];
      Future<void> put(String metric, num v) async {
        await Store.instance.putSamples(dev, metric, [Sample(now, v.toDouble())]);
        bits.add('$metric $v');
      }

      // A zero is the band's "no reading" filler, never a measurement.
      if (got != null) {
        if (got.heartRate > 0) await put('heart_rate', got.heartRate);
        if (got.spo2 > 0) await put('spo2', got.spo2);
        if (got.hrvMs > 0) await put('hrv', got.hrvMs);
      }
      if (tempC != null) await put('temperature', tempC);

      lastSampleAt = now;
      lastResult = bits.isEmpty ? 'no reading' : bits.join(' · ');
      if (bits.isEmpty) {
        _link.log.add('periodic sample: sensor did not converge');
      }
    } catch (e) {
      _link.log.add('minute sample failed: $e');
    } finally {
      _running = false;
    }
  }
}
