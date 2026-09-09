import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/analytics/sleep.dart';
import 'package:aurav5/protocol/jstyle.dart';

/// These are the actual 0x53 records captured from JCV8B 44300D on
/// 2026-08-26, and the expected values are what the vendor app displayed for
/// the same night. If our parsing or formatting drifts, this catches it.
void main() {
  // Real bytes, in the order the band sent them.
  final raw = <String>[
    '5300002608260801040902010201020201010201040404000000000000000000',
    '530100260826060101780101010101010101010101010102010202020202020202020202',
    '530200260826040101780202020202020202020202020202020202010202020201010100',
    '530300260826020101780a04040402020202020202020202020202020101010102010100',
    '5304002608260041024b0f0404040202020202020202020202020202020202020101 0100'
        .replaceAll(' ', ''),
  ];

  List<SleepSegment> segments() => raw
      .map((h) {
        final b = <int>[];
        for (var i = 0; i + 1 < h.length; i += 2) {
          b.add(int.parse(h.substring(i, i + 2), radix: 16));
        }
        // pad to the 34-byte stride the band uses
        while (b.length < 34) {
          b.add(0);
        }
        return parseSleepRecord(b);
      })
      .whereType<SleepSegment>()
      .toList();

  group('0x53 sleep records', () {
    test('every captured record parses', () {
      expect(segments().length, raw.length);
    });

    test('segment duration comes from byte 9', () {
      final s = segments().firstWhere((e) => e.start.hour == 8);
      expect(s.minutes, 9);
      // 08:01 + 9 min = 08:10, which is exactly the wake time the vendor showed
      expect(s.end.hour, 8);
      expect(s.end.minute, 10);
    });

    test('the night reconstructs to the vendor window, 00:41 - 08:10', () {
      final nights = buildNights(segments());
      expect(nights.length, 1, reason: 'segments should group into one night');
      final n = nights.single;
      expect(n.start.hour, 0);
      expect(n.start.minute, 41);
      expect(n.end.hour, 8);
      expect(n.end.minute, 10);
      expect(n.inBed.inMinutes, 449); // vendor: In Bed 7h29m
    });

    test('only the three stages the band actually reports appear', () {
      final n = buildNights(segments()).single;
      expect(n.stageMinutes.keys.toSet(),
          {SleepStage.deep, SleepStage.light, SleepStage.awake});
      // The vendor's fourth stage (REM) is derived on the phone, never sent.
    });

    test('stage split is in the same ballpark as the vendor', () {
      final n = buildNights(segments()).single;
      // vendor: Light 57%, Deep 25%, Awake ~4%
      expect(n.pct(SleepStage.light), inInclusiveRange(55, 72));
      expect(n.pct(SleepStage.deep), inInclusiveRange(20, 35));
      expect(n.pct(SleepStage.awake), inInclusiveRange(2, 12));
    });
  });

  group('duration formatting', () {
    // The whole point: a 449-minute night must never render as "449m".
    test('renders hours once there is at least one', () {
      expect(formatHm(const Duration(minutes: 449)), '7h 29m');
      expect(formatHm(const Duration(minutes: 430)), '7h 10m');
      expect(formatHm(const Duration(minutes: 247)), '4h 7m');
      expect(formatHm(const Duration(minutes: 107)), '1h 47m');
      expect(formatHm(const Duration(minutes: 60)), '1h');
    });

    test('keeps sub-hour values in minutes', () {
      expect(formatHm(const Duration(minutes: 19)), '19m');
      expect(formatHm(const Duration(minutes: 4)), '4m');
      expect(formatHm(Duration.zero), '0m');
    });

    test('never emits a bare minute count above an hour', () {
      for (var m = 1; m <= 1000; m++) {
        final s = formatHm(Duration(minutes: m));
        if (m >= 60) {
          expect(s, contains('h'), reason: '$m min rendered as "$s"');
        }
      }
    });

    test('the real night formats correctly everywhere it is shown', () {
      final n = buildNights(segments()).single;
      expect(formatHm(n.inBed), '7h 29m');
      expect(formatHm(n.totalSleep), contains('h'));
      for (final code in [SleepStage.light, SleepStage.deep]) {
        final mins = Duration(minutes: (n.stageMinutes[code] ?? 0).round());
        expect(formatHm(mins), contains('h'),
            reason: '${SleepStage.label(code)} should show hours');
      }
    });
  });

  group('nap threshold', () {
    test('a short fragment is a nap, never "last night"', () {
      // A 9-minute tail on its own must not become the displayed night — that
      // is what made every value render in minutes.
      final fragment = SleepSegment(
          DateTime(2026, 8, 26, 14, 0), 9, [SleepStage.light, SleepStage.deep]);
      final all = buildNights([...segments(), fragment]);
      expect(all.length, 2, reason: 'the fragment is its own group');

      final nights = nightsOnly(all);
      final naps = napsOnly(all);
      expect(nights.length, 1);
      expect(naps.length, 1);
      expect(nights.single.inBed.inMinutes, 449);
      expect(naps.single.inBed.inMinutes, 9);

      // and the displayed night therefore always reads in hours
      expect(formatHm(nights.single.inBed), '7h 29m');
    });

    test('the real night is not misclassified as a nap', () {
      expect(nightsOnly(buildNights(segments())).length, 1);
      expect(napsOnly(buildNights(segments())), isEmpty);
    });
  });

  group('a dropped segment must not truncate the night', () {
    // Reproduces exactly what the phone stored: the 06:01 segment went
    // missing during sync, leaving a 120-minute hole in the middle.
    List<SleepSegment> withHole() =>
        segments().where((s) => s.start.hour != 6).toList();

    test('the real sync dropped one segment', () {
      expect(segments().length, 5);
      expect(withHole().length, 4);
    });

    test('the night still spans 00:41 to 08:10 despite the hole', () {
      final nights = nightsOnly(buildNights(withHole()));
      expect(nights.length, 1,
          reason: 'a 120-minute hole must not split the night');
      expect(nights.single.inBed.inMinutes, 449);
      expect(formatHm(nights.single.inBed), '7h 29m');
    });

    test('the hole is not silently counted as sleep', () {
      // inBed still spans the gap, but the stages do not cover it. Taking
      // totalSleep as (inBed - awake) counted the missing 120 minutes as
      // sleep, so the headline figure and the stage rows disagreed by exactly
      // the size of the hole.
      final n = nightsOnly(buildNights(withHole())).single;
      final staged = n.stageMinutes.values.fold<double>(0, (a, b) => a + b);
      expect(n.totalSleep.inMinutes + n.awakeMinutes.round(),
          closeTo(staged, 1.5),
          reason: 'total sleep + awake must equal what the stages actually '
              'account for');
      expect(n.unaccounted.inMinutes, greaterThan(60),
          reason: 'the dropped segment should be reported as unaccounted');
      expect(n.totalSleep, lessThan(n.inBed));
    });

    test('a complete night is accounted for within a few minutes', () {
      // Not zero: the segments' declared durations sum to 444 min while the
      // window spans 449, because the first segment declares 75 min but the
      // next one starts 79 min later. That 5-minute residue is inherent to
      // the band's own bookkeeping — what matters is that it stays an order
      // of magnitude below a dropped segment (120+ min).
      final n = nightsOnly(buildNights(segments())).single;
      expect(n.unaccounted.inMinutes, lessThan(10));

      final holed = nightsOnly(buildNights(withHole())).single;
      expect(holed.unaccounted.inMinutes,
          greaterThan(n.unaccounted.inMinutes * 5),
          reason: 'a real gap must be clearly distinguishable from the '
              'residue of a complete night');
    });

    test('a genuine nap hours later is still separate', () {
      final nap = SleepSegment(
          DateTime(2026, 8, 26, 14, 0), 40, [SleepStage.light]);
      final all = buildNights([...segments(), nap]);
      expect(nightsOnly(all).length, 1);
      expect(napsOnly(all).length, 1);
      expect(napsOnly(all).single.inBed.inMinutes, 40);
    });
  });

  group('derived sleep metrics', () {
    test('efficiency and latency are plausible', () {
      final n = buildNights(segments()).single;
      expect(n.efficiency, inInclusiveRange(80, 100));
      expect(n.latency.inMinutes, inInclusiveRange(0, 90));
    });

    test('score lands in range with a sensible label', () {
      final n = buildNights(segments()).single;
      expect(n.score, inInclusiveRange(0, 100));
      expect(n.stars, inInclusiveRange(1, 5));
      expect(['Excellent', 'Good', 'Fair', 'Poor'], contains(n.scoreLabel));
    });
  });
}
