/// Derived health metrics.
///
/// The vendor app ships BioAge, VO2Max, Strain/Recovery and cycle tracking.
/// **None of these are transmitted by the band** — the band sends heart rate,
/// HRV, SpO2, skin temperature, steps and sleep, and the vendor computes the
/// rest on the phone from published (or invented) formulas.
///
/// So these are *our* implementations, built from the same inputs using
/// methods that are cited and checkable. They will not reproduce the vendor's
/// numbers, and nothing here is a medical device or a diagnosis.
///
/// Every estimator returns null rather than guessing when its inputs are
/// missing or out of range — a fabricated score is worse than a blank card.
library;

import 'dart:math' as math;

import '../data/store.dart';

/// A value plus how much to trust it.
class Estimate {
  final double value;
  final String unit;

  /// 0..1. Driven by how much data actually backed the estimate.
  final double confidence;

  /// Short, honest explanation of what produced this number.
  final String basis;

  const Estimate(this.value, this.unit, this.confidence, this.basis);

  String get display => value.abs() >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1);

  String get confidenceLabel => switch (confidence) {
        >= 0.75 => 'good data',
        >= 0.45 => 'limited data',
        _ => 'very little data',
      };
}

// ---------------------------------------------------------------- helpers

double? _mean(Iterable<double> xs) {
  final l = xs.toList();
  if (l.isEmpty) return null;
  return l.reduce((a, b) => a + b) / l.length;
}

double? _percentile(List<double> xs, double p) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final i = ((s.length - 1) * p).round().clamp(0, s.length - 1);
  return s[i];
}

double _sd(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = xs.reduce((a, b) => a + b) / xs.length;
  final v = xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) /
      (xs.length - 1);
  return math.sqrt(v);
}

/// Samples between two times of day, crossing midnight.
List<Sample> _nightWindow(List<Sample> xs, {int fromHour = 0, int toHour = 6}) =>
    xs.where((s) => s.at.hour >= fromHour && s.at.hour < toHour).toList();

/// Lowest rolling mean over [window] consecutive samples — a much more stable
/// resting-rate estimator than a plain minimum, which just finds the noise
/// floor.
double? _lowestRollingMean(List<double> xs, int window) {
  if (xs.length < window) return xs.isEmpty ? null : _mean(xs);
  var best = double.infinity;
  var sum = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sum += xs[i];
    if (i >= window) sum -= xs[i - window];
    if (i >= window - 1) best = math.min(best, sum / window);
  }
  return best.isFinite ? best : null;
}

// ------------------------------------------------------------ resting HR

/// Resting heart rate: the lowest sustained 5-sample mean during the night.
///
/// At the band's confirmed 5-second sampling that is a 25-second plateau,
/// which rejects single-sample artefacts without smoothing away real dips.
Estimate? restingHeartRate(List<Sample> hr) {
  final night = _nightWindow(hr);
  final pool = (night.length >= 20 ? night : hr).map((s) => s.value).toList();
  if (pool.length < 5) return null;
  final v = _lowestRollingMean(pool, 5);
  if (v == null || v < 30 || v > 120) return null;
  return Estimate(
    v,
    'bpm',
    (pool.length / 200).clamp(0.2, 1.0) * (night.length >= 20 ? 1.0 : 0.6),
    night.length >= 20
        ? 'lowest sustained 25 s during 00:00–06:00'
        : 'lowest sustained 25 s (no overnight data yet)',
  );
}

/// Waking resting heart rate — measured awake and at rest.
///
/// A different quantity from the overnight minimum, and the one the VO2max
/// relation actually requires. Daytime hours only, lowest sustained plateau,
/// with a floor that rejects a sleeping value leaking in.
Estimate? wakingRestingHeartRate(List<Sample> hr) {
  final day = hr
      .where((s) => s.at.hour >= 8 && s.at.hour < 22)
      .map((s) => s.value)
      .toList();
  if (day.length < 30) return null;
  final v = _lowestRollingMean(day, 12); // a full minute at 5 s sampling
  if (v == null || v < 45 || v > 120) return null;
  return Estimate(
    v,
    'bpm',
    (day.length / 500).clamp(0.2, 1.0),
    'lowest sustained minute while awake (08:00–22:00)',
  );
}

// -------------------------------------------------------------- recovery

/// Recovery, 0–100.
///
/// Follows the shape used across the recovery-score literature: today's
/// overnight HRV and resting HR compared against the wearer's own rolling
/// baseline, not against population norms. HRV carries the most weight because
/// it is the most responsive to autonomic load.
///
/// Needs a baseline to mean anything, so it refuses to score until there are
/// at least three prior nights.
Estimate? recovery({
  required List<Sample> hrvHistory,
  required List<Sample> hrHistory,
}) {
  if (hrvHistory.length < 4) return null;

  // Zero-padded, so a lexicographic sort really is chronological. Without the
  // padding "2026-8-10" sorts BEFORE "2026-8-9" and days.last picks the wrong
  // night as "today".
  String dayKey(DateTime t) => '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  final byDay = <String, List<double>>{};
  for (final s in hrvHistory) {
    (byDay[dayKey(s.at)] ??= []).add(s.value);
  }
  final days = byDay.keys.toList()..sort();
  if (days.length < 4) return null;

  final todayHrv = _mean(byDay[days.last]!)!;
  final baselineDays = days.sublist(0, days.length - 1);
  final baselineVals =
      baselineDays.expand((d) => byDay[d]!).map((v) => v).toList();
  final baseHrv = _mean(baselineVals)!;
  final sd = _sd(baselineVals);
  if (baseHrv <= 0) return null;

  // With no spread there is no baseline to score against, and every night
  // would come back as exactly 50 — a number that looks measured but is not.
  if (sd <= 0) return null;

  // z-score of today's HRV against the wearer's own spread, then squashed to
  // 0..100 with 50 = exactly at baseline.
  final z = (todayHrv - baseHrv) / sd;
  var score = 50 + 20 * z.clamp(-2.5, 2.5);

  // Resting HR pulls the other way: elevated RHR is a well-established marker
  // of incomplete recovery.
  //
  // Both sides must be the SAME statistic or the comparison is meaningless.
  // This previously compared today's lowest sustained mean against the 10th
  // percentile of every sample, and the former is essentially always the
  // lower of the two — so the penalty it documents could never fire and the
  // term only ever ADDED points.
  final todayHr = hrHistory
      .where((s) => dayKey(s.at) == days.last)
      .map((s) => s.value)
      .toList();
  final priorHr = hrHistory
      .where((s) => dayKey(s.at) != days.last)
      .map((s) => s.value)
      .toList();
  if (todayHr.length >= 20 && priorHr.length >= 50) {
    final todayLow = _lowestRollingMean(todayHr, 5);
    final baseLow = _lowestRollingMean(priorHr, 5);
    if (todayLow != null && baseLow != null && baseLow > 0) {
      // Positive delta = resting rate up on baseline = worse recovery.
      score -= (todayLow - baseLow).clamp(-10.0, 15.0) * 1.5;
    }
  }

  return Estimate(
    score.clamp(0, 100),
    '',
    (baselineDays.length / 14).clamp(0.25, 1.0),
    'overnight HRV vs your own ${baselineDays.length}-night baseline',
  );
}

// ----------------------------------------------------------------- strain

/// Strain, 0–21 (Borg-like compression of cardiovascular load).
///
/// Time-weighted accumulation of heart rate above resting, scaled by heart-rate
/// reserve. This is the standard TRIMP-style approach; the 0–21 range is a
/// presentation choice, chosen because a logarithmic compression keeps easy
/// days distinguishable while hard days do not saturate.
Estimate? strain({
  required List<Sample> hrToday,
  required int age,
  Estimate? resting,
}) {
  if (hrToday.length < 10) return null;
  final rest = resting?.value ?? 60;
  final maxHr = 208 - 0.7 * age; // Tanaka, more accurate than 220-age
  final reserve = maxHr - rest;
  if (reserve <= 0) return null;

  var load = 0.0;
  for (var i = 1; i < hrToday.length; i++) {
    final dt = hrToday[i].at.difference(hrToday[i - 1].at).inSeconds;
    // Gaps longer than 5 minutes mean the band was off or idle; do not
    // integrate across them or a removed band reads as a workout.
    if (dt <= 0 || dt > 300) continue;
    final frac = ((hrToday[i].value - rest) / reserve).clamp(0.0, 1.0);
    load += frac * frac * dt / 60.0;
  }
  if (load <= 0) return null;
  final s = 21 * (1 - math.exp(-load / 45));
  return Estimate(s.clamp(0, 21), '', (hrToday.length / 300).clamp(0.2, 1.0),
      'HR-reserve weighted load over ${hrToday.length} samples');
}

// ----------------------------------------------------------------- VO2max

/// VO2max estimate, ml/kg/min.
///
/// Uses the Uth–Sørensen–Overgaard–Pedersen relation, VO2max ≈ 15.3 × HRmax/HRrest,
/// which is the only widely validated method that needs *no* exercise test —
/// exactly our situation, since the band gives resting data.
///
/// Its published accuracy is roughly ±10–15%, so this is a trend indicator,
/// not a number to compare against a lab test.
/// [waking] must be a WAKING resting heart rate, not the overnight minimum.
///
/// Conflating the two is a real error and it bit this app: feeding the
/// sleeping nadir of 40 bpm into this relation produced 70.2 ml/kg/min —
/// elite-athlete territory — and a biological age 17 years below actual.
/// Uth–Sørensen was validated against resting HR taken awake and seated.
Estimate? vo2max({required Estimate? waking, required int age}) {
  if (waking == null) return null;
  final maxHr = 208 - 0.7 * age;
  final v = 15.3 * (maxHr / waking.value);
  // Above ~65 is endurance-athlete territory. Reaching it from a resting
  // heart rate alone means the input is far likelier to be wrong than the
  // person to be an elite athlete, so refuse rather than flatter.
  if (v < 15 || v > 65) return null;
  return Estimate(v, 'ml/kg/min', waking.confidence * 0.6,
      'Uth–Sørensen ratio from waking resting HR (±10–15%)');
}

// ---------------------------------------------------------------- BioAge

/// "Biological age", in years.
///
/// Presented deliberately as an offset from chronological age. There is no
/// accepted clinical definition of biological age from wearable data, so this
/// is a fitness-weighted heuristic: VO2max and HRV both decline with age at
/// known population rates, and we invert those to express current values as an
/// age equivalent.
///
/// Treat it as a motivational summary of cardiorespiratory fitness, not a
/// measure of ageing.
Estimate? bioAge({
  required int chronologicalAge,
  Estimate? vo2,
  List<Sample> hrv = const [],
}) {
  final parts = <double>[];

  if (vo2 != null) {
    // Population VO2max declines ~0.4 ml/kg/min per year; anchor at a
    // reference of 45 at age 30 for men and women combined.
    final expectedAt30 = 45.0;
    final ageEquivalent = 30 + (expectedAt30 - vo2.value) / 0.40;
    parts.add(ageEquivalent);
  }

  if (hrv.length >= 20) {
    final m = _mean(hrv.map((s) => s.value))!;
    // RMSSD falls roughly exponentially with age; ~60 ms at 20, ~25 ms at 60.
    if (m > 5 && m < 200) {
      final ageEquivalent = 20 + (60 - m) * (40 / 35);
      parts.add(ageEquivalent);
    }
  }

  if (parts.isEmpty) return null;
  final raw = _mean(parts)!;

  // Refuse rather than clamp. Clamping turned a wildly out-of-range
  // age-equivalent into a confident "18.0 years" — the shape of a real answer
  // with none of the substance. If the inputs imply something absurd, the
  // honest output is no output.
  if (raw < chronologicalAge - 25 || raw > chronologicalAge + 30) return null;

  // Within that sanity window, still keep the displayed figure to a
  // defensible distance from actual age.
  final est = raw
      .clamp(chronologicalAge - 12.0, chronologicalAge + 15.0)
      .clamp(18.0, 90.0);
  return Estimate(
    est,
    'years',
    parts.length >= 2 ? 0.6 : 0.35,
    parts.length >= 2
        ? 'fitness-weighted from VO2max and HRV'
        : 'fitness-weighted from ${vo2 != null ? "VO2max" : "HRV"} only',
  );
}

// ---------------------------------------------------- cycle / women's health

enum CyclePhase { menstrual, follicular, ovulatory, luteal, unknown }

extension CyclePhaseLabel on CyclePhase {
  String get label => switch (this) {
        CyclePhase.menstrual => 'Menstrual',
        CyclePhase.follicular => 'Follicular',
        CyclePhase.ovulatory => 'Fertile window',
        CyclePhase.luteal => 'Luteal',
        CyclePhase.unknown => 'Not enough data',
      };
}

class CycleView {
  final CyclePhase phase;
  final int? dayOfCycle;
  final DateTime? predictedNextPeriod;
  final double? temperatureShiftC;
  final String basis;
  const CycleView(this.phase, this.dayOfCycle, this.predictedNextPeriod,
      this.temperatureShiftC, this.basis);
}

/// Cycle phase from logged period starts plus the nocturnal temperature shift.
///
/// The temperature part is the physiologically real signal: the post-ovulatory
/// progesterone rise lifts nocturnal skin temperature by roughly 0.3 °C, which
/// *confirms* ovulation retrospectively. It does not predict it — prediction
/// comes from the wearer's own cycle-length history.
///
/// The band quantises temperature to 0.1 °C, only ~3× smaller than the signal,
/// so a shift is only reported when it clears a margin above baseline noise.
///
/// This is fertility *awareness*. It is not contraception.
CycleView cycleStatus({
  required List<DateTime> periodStarts,
  required List<Sample> nightTemperature,
}) {
  if (periodStarts.isEmpty) {
    return const CycleView(CyclePhase.unknown, null, null, null,
        'log a period start to begin tracking');
  }

  final starts = [...periodStarts]..sort();
  final last = starts.last;
  final day = DateTime.now().difference(last).inDays + 1;

  // A start logged in the future is a mis-tap, not a cycle.
  if (day < 1) {
    return const CycleView(CyclePhase.unknown, null, null, null,
        'that period start is in the future — check the date');
  }

  // Median observed cycle length beats a fixed 28 for anyone who is not
  // textbook-regular.
  var cycleLength = 28;
  if (starts.length >= 2) {
    final gaps = <int>[];
    for (var i = 1; i < starts.length; i++) {
      final g = starts[i].difference(starts[i - 1]).inDays;
      if (g >= 21 && g <= 40) gaps.add(g);
    }
    if (gaps.isNotEmpty) {
      gaps.sort();
      cycleLength = gaps[gaps.length ~/ 2];
    }
  }

  // Nocturnal temperature shift: last 3 nights against the 10 before them.
  double? shift;
  final nights = _nightWindow(nightTemperature, fromHour: 1, toHour: 5);
  if (nights.length >= 12) {
    final byDay = <String, List<double>>{};
    for (final s in nights) {
      // Zero-padded so the sort below is chronological, not lexicographic.
      final k = '${s.at.year.toString().padLeft(4, '0')}-'
          '${s.at.month.toString().padLeft(2, '0')}-'
          '${s.at.day.toString().padLeft(2, '0')}';
      (byDay[k] ??= []).add(s.value);
    }
    final keys = byDay.keys.toList()..sort();
    if (keys.length >= 6) {
      final recent = keys.sublist(keys.length - 3);
      final base = keys.sublist(0, keys.length - 3);
      final r = _mean(recent.expand((k) => byDay[k]!))!;
      final b = _mean(base.expand((k) => byDay[k]!))!;
      final d = r - b;
      // 0.15 °C floor keeps 0.1 °C quantisation noise from reading as a shift.
      if (d.abs() >= 0.15) shift = d;
    }
  }

  // A log that is more than a cycle-and-a-half old cannot place today in a
  // phase, and predicting from it puts the "next period" date in the PAST
  // while quietly falling through to Luteal. Say it is stale instead.
  if (day > cycleLength + 14) {
    return CycleView(
      CyclePhase.unknown,
      day,
      null,
      shift,
      'last logged period was $day days ago — log the latest one to resume '
          'tracking',
    );
  }

  final next = last.add(Duration(days: cycleLength));
  CyclePhase phase;
  if (day <= 5) {
    phase = CyclePhase.menstrual;
  } else if (shift != null && shift > 0) {
    phase = CyclePhase.luteal; // temperature confirms ovulation has passed
  } else if (day >= cycleLength - 19 && day <= cycleLength - 12) {
    phase = CyclePhase.ovulatory;
  } else if (day < cycleLength - 19) {
    phase = CyclePhase.follicular;
  } else {
    phase = CyclePhase.luteal;
  }

  return CycleView(
    phase,
    day,
    next,
    shift,
    shift != null
        ? 'cycle day $day of ~$cycleLength, temperature shift '
            '${shift > 0 ? "+" : ""}${shift.toStringAsFixed(2)} °C'
        : 'cycle day $day of ~$cycleLength (no temperature shift detected)',
  );
}

// ------------------------------------------------------------------ sleep

class SleepSummary {
  final Duration total;
  final DateTime? start, end;
  final double? avgHr, avgSpo2, lowestSpo2;
  const SleepSummary(
      this.total, this.start, this.end, this.avgHr, this.avgSpo2, this.lowestSpo2);
}

/// Infer a sleep window from heart-rate data when the band has no stored sleep
/// records — which is the normal case until background monitoring is enabled.
///
/// Finds the longest overnight stretch where heart rate sits near its resting
/// plateau. Crude next to a real staging algorithm, but honest about it, and
/// it produces something useful from data we definitely have.
SleepSummary? inferSleep({
  required List<Sample> hr,
  required List<Sample> spo2,
  Estimate? resting,
}) {
  if (hr.length < 30) return null;
  final rest = resting?.value ?? _percentile(hr.map((e) => e.value).toList(), 0.1);
  if (rest == null) return null;
  final threshold = rest * 1.12;

  DateTime? bestStart, bestEnd, curStart;
  Duration best = Duration.zero;
  DateTime? prev;
  for (final s in hr) {
    final asleep = s.value <= threshold;
    if (asleep) {
      curStart ??= s.at;
      if (prev != null && s.at.difference(prev).inMinutes > 20) {
        curStart = s.at; // gap breaks the stretch
      }
      final len = s.at.difference(curStart);
      if (len > best) {
        best = len;
        bestStart = curStart;
        bestEnd = s.at;
      }
    } else {
      curStart = null;
    }
    prev = s.at;
  }
  if (bestStart == null || best.inMinutes < 90) return null;

  bool inWindow(Sample s) =>
      !s.at.isBefore(bestStart!) && !s.at.isAfter(bestEnd!);
  final nightHr = hr.where(inWindow).map((s) => s.value).toList();
  final nightSpo2 = spo2.where(inWindow).map((s) => s.value).toList();

  return SleepSummary(
    best,
    bestStart,
    bestEnd,
    _mean(nightHr),
    _mean(nightSpo2),
    nightSpo2.isEmpty ? null : nightSpo2.reduce(math.min),
  );
}
