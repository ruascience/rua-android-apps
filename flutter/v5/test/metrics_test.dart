import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/analytics/metrics.dart';
import 'package:aurav5/data/store.dart';

/// Guards against derived metrics being computed from too little data and
/// presented as if they were solid. On real data the band's overnight low was
/// 40 bpm (matching the vendor exactly), but the app briefly displayed 84 —
/// because the page had loaded before the sync filled the database.
void main() {
  List<Sample> night({required int lowest, int count = 400}) {
    final base = DateTime(2026, 8, 26, 0, 30);
    return List.generate(count, (i) {
      // a realistic night: mostly mid-70s with a sustained dip to `lowest`
      final v = (i >= 100 && i < 140) ? lowest : 76 + (i % 7);
      return Sample(base.add(Duration(seconds: i * 5)), v.toDouble());
    });
  }

  group('resting heart rate', () {
    test('finds the sustained overnight low, not the daytime average', () {
      final e = restingHeartRate(night(lowest: 40))!;
      expect(e.value, closeTo(40, 0.01));
      expect(e.basis, contains('00:00'));
    });

    test('a single stray low sample cannot drag it down', () {
      final s = night(lowest: 76);
      // one impossible artefact in the middle
      s[200] = Sample(s[200].at, 31);
      final e = restingHeartRate(s)!;
      // the 5-sample plateau rejects it rather than reporting 31
      expect(e.value, greaterThan(60));
    });

    test('too little data is reported as low confidence, not as a number '
        'to trust', () {
      final few = night(lowest: 84, count: 8);
      final e = restingHeartRate(few);
      expect(e, isNotNull);
      // 8 daytime-ish samples must never look authoritative
      expect(e!.confidence, lessThan(0.45));
      expect(e.confidenceLabel, 'very little data');
    });

    test('refuses to guess from nothing', () {
      expect(restingHeartRate(const []), isNull);
      expect(restingHeartRate(night(lowest: 60, count: 3)), isNull);
    });
  });

  group('VO2max needs a WAKING resting rate', () {
    // Daytime samples, awake hours, with a sustained plateau at `low`.
    List<Sample> day({required int low, int count = 600}) {
      final base = DateTime(2026, 8, 26, 10, 0);
      return List.generate(count, (i) {
        final v = (i >= 200 && i < 260) ? low : low + 18 + (i % 9);
        return Sample(base.add(Duration(seconds: i * 5)), v.toDouble());
      });
    }

    test('a fitter waking rate gives a higher VO2max', () {
      final fit = vo2max(waking: wakingRestingHeartRate(day(low: 52)), age: 35)!;
      final unfit =
          vo2max(waking: wakingRestingHeartRate(day(low: 78)), age: 35)!;
      expect(fit.value, greaterThan(unfit.value));
      for (final e in [fit, unfit]) {
        expect(e.value, inInclusiveRange(15, 65));
      }
    });

    test('the overnight minimum is refused, not silently accepted', () {
      // 40 bpm asleep put through this relation yields 70.2 — elite-athlete
      // territory — which is exactly the bug this guards.
      final sleeping = restingHeartRate(night(lowest: 40));
      expect(sleeping!.value, closeTo(40, 0.01));
      expect(vo2max(waking: sleeping, age: 35), isNull,
          reason: 'a sleeping nadir must not be accepted as a waking rate');
    });

    test('waking estimator ignores the night entirely', () {
      // Only overnight samples: there is no waking rate to report.
      expect(wakingRestingHeartRate(night(lowest: 40)), isNull);
    });

    test('BioAge cannot claim an implausible age gap', () {
      final v = vo2max(waking: wakingRestingHeartRate(day(low: 46)), age: 35);
      final b = bioAge(chronologicalAge: 35, vo2: v);
      if (b != null) {
        expect(b.value, inInclusiveRange(23, 50),
            reason: 'must stay within a defensible window of actual age');
        expect(b.confidence, lessThan(0.5));
      }
    });

    test('BioAge refuses to score with no inputs at all', () {
      expect(bioAge(chronologicalAge: 35, vo2: null), isNull);
    });
  });

  group('audit regressions', () {
    List<Sample> hrvOn(List<DateTime> days, double value) => [
          for (final d in days)
            for (var i = 0; i < 5; i++)
              Sample(d.add(Duration(minutes: i * 10)), value + i),
        ];

    test('day keys sort chronologically across the 9th/10th boundary', () {
      // Unpadded keys sort "2026-8-10" BEFORE "2026-8-9", so the 9th would be
      // treated as the most recent night and scored as "today".
      final days = [
        DateTime(2026, 8, 8, 2),
        DateTime(2026, 8, 9, 2),
        DateTime(2026, 8, 10, 2),
        DateTime(2026, 8, 11, 2),
      ];
      final hrv = <Sample>[
        ...hrvOn(days.sublist(0, 3), 50),
        // the genuinely most recent night is clearly different
        ...hrvOn([days[3]], 20),
      ];
      final r = recovery(hrvHistory: hrv, hrHistory: const []);
      expect(r, isNotNull);
      // the 11th (low HRV) must be scored as today, so recovery is BELOW 50
      expect(r!.value, lessThan(50),
          reason: 'the most recent night must be the one scored');
    });

    test('a baseline with no spread is refused, not scored as exactly 50', () {
      final flat = [
        for (var d = 1; d <= 4; d++)
          for (var i = 0; i < 5; i++)
            Sample(DateTime(2026, 8, d, 2, i * 10), 45),
      ];
      expect(recovery(hrvHistory: flat, hrHistory: const []), isNull);
    });

    test('BioAge refuses an absurd age-equivalent instead of clamping it', () {
      // A VO2max far outside anything the inputs could justify used to be
      // clamped into a confident "18.0 years".
      final absurd = const Estimate(120, 'ml/kg/min', 0.5, 'synthetic');
      expect(bioAge(chronologicalAge: 35, vo2: absurd), isNull);
    });

    test('a stale period log does not predict a date in the past', () {
      final old = DateTime.now().subtract(const Duration(days: 120));
      final c = cycleStatus(periodStarts: [old], nightTemperature: const []);
      expect(c.phase, CyclePhase.unknown);
      expect(c.predictedNextPeriod, isNull,
          reason: 'must not offer a next-period date derived from a stale log');
      expect(c.basis, contains('log the latest'));
    });

    test('a period start in the future is rejected', () {
      final future = DateTime.now().add(const Duration(days: 3));
      final c = cycleStatus(periodStarts: [future], nightTemperature: const []);
      expect(c.phase, CyclePhase.unknown);
      expect(c.basis, contains('future'));
    });
  });
}
