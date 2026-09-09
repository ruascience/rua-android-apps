/// Sleep night assembly and scoring.
///
/// The band gives us segments of stage codes (opcode 0x53). Everything the
/// vendor's sleep screen shows beyond that — efficiency, latency, debt, the
/// score, the quality badges — is computed on the phone. These are our own
/// implementations using standard sleep-medicine definitions.
library;

import 'dart:math' as math;

import '../data/store.dart';
import '../protocol/jstyle.dart' as j;

/// One stage block on the hypnogram.
class StageBlock {
  final DateTime start;
  final DateTime end;
  final int code;
  const StageBlock(this.start, this.end, this.code);
  int get minutes => end.difference(start).inMinutes;
}

/// Quality rating, mirroring the vendor's badge vocabulary.
enum Rating { optimal, good, needsAttention, unknown }

extension RatingLabel on Rating {
  String get label => switch (this) {
        Rating.optimal => 'Optimal',
        Rating.good => 'Good',
        Rating.needsAttention => 'Needs Attention',
        Rating.unknown => '—',
      };
}

class MetricSummary {
  final double? avg, lowest, highest;
  final Rating avgRating, lowestRating;
  const MetricSummary(this.avg, this.lowest, this.highest, this.avgRating,
      this.lowestRating);
}

class SleepNight {
  final DateTime start, end;
  final List<StageBlock> blocks;

  /// Minutes per stage code, keyed by [j.SleepStage].
  final Map<int, double> stageMinutes;

  const SleepNight(this.start, this.end, this.blocks, this.stageMinutes);

  /// Time between first and last stage sample — the vendor's "In Bed Duration".
  Duration get inBed => end.difference(start);

  /// Time actually scored as a sleep stage — the vendor's "Total Sleep Time".
  ///
  /// Summed from the stages rather than taken as `inBed − awake`. Those agree
  /// when every segment arrived, but when one is dropped the window still
  /// spans the hole while the stages do not, and the subtraction silently
  /// counts the missing period as sleep — leaving Total Sleep Time and the
  /// stage rows disagreeing by exactly the size of the gap.
  Duration get totalSleep {
    final asleep = stageMinutes.entries
        .where((e) => e.key != j.SleepStage.awake)
        .fold<double>(0, (a, e) => a + e.value);
    return Duration(minutes: asleep.round().clamp(0, inBed.inMinutes));
  }

  /// Minutes inside the window that no segment accounted for — a dropped
  /// segment, in other words. Non-zero means the night is incomplete.
  Duration get unaccounted {
    final covered =
        stageMinutes.values.fold<double>(0, (a, b) => a + b).round();
    final gap = inBed.inMinutes - covered;
    return Duration(minutes: gap > 0 ? gap : 0);
  }

  /// Asleep / in bed. The standard clinical definition; ≥85% is normal.
  double get efficiency =>
      inBed.inMinutes == 0 ? 0 : totalSleep.inMinutes / inBed.inMinutes * 100;

  /// Time from getting into bed to the first non-awake stage.
  Duration get latency {
    for (final b in blocks) {
      if (b.code != j.SleepStage.awake) return b.start.difference(start);
    }
    return Duration.zero;
  }

  double get deepMinutes => stageMinutes[j.SleepStage.deep] ?? 0;
  double get lightMinutes => stageMinutes[j.SleepStage.light] ?? 0;
  double get awakeMinutes => stageMinutes[j.SleepStage.awake] ?? 0;

  double pct(int code) {
    final total = stageMinutes.values.fold<double>(0, (a, b) => a + b);
    return total == 0 ? 0 : (stageMinutes[code] ?? 0) / total * 100;
  }

  /// Shortfall against a target. The vendor calls this "sleep debt".
  Duration debt({Duration target = const Duration(hours: 8, minutes: 15)}) {
    final d = target - totalSleep;
    return d.isNegative ? Duration.zero : d;
  }

  /// Sleep score, 0–100.
  ///
  /// Weighted the way the major scores are: duration dominates, then
  /// efficiency, then how much deep sleep was achieved. Ours, not the
  /// vendor's — theirs is undisclosed, so the numbers will differ.
  int get score {
    final hours = totalSleep.inMinutes / 60.0;
    // Duration: full marks at 7.5–9 h, tapering either side.
    final dur = hours >= 7.5 && hours <= 9
        ? 1.0
        : (hours < 7.5 ? (hours / 7.5) : math.max(0.0, 1 - (hours - 9) / 3));
    final eff = (efficiency / 95).clamp(0.0, 1.0);
    // Deep sleep: 13–23% of the night is the usual adult range.
    final deepPct = pct(j.SleepStage.deep);
    final deep = deepPct >= 13 && deepPct <= 25
        ? 1.0
        : (deepPct < 13 ? deepPct / 13 : math.max(0.0, 1 - (deepPct - 25) / 20));
    final s = 100 * (0.55 * dur + 0.25 * eff + 0.20 * deep);
    return s.round().clamp(0, 100);
  }

  String get scoreLabel => switch (score) {
        >= 85 => 'Excellent',
        >= 70 => 'Good',
        >= 55 => 'Fair',
        _ => 'Poor',
      };

  int get stars => switch (score) {
        >= 90 => 5,
        >= 75 => 4,
        >= 60 => 3,
        >= 45 => 2,
        _ => 1,
      };
}

/// A block under this long is a nap, not a night.
///
/// This is the vendor's own rule, stated on their sleep screen: "If sleep
/// duration is less than 1 hour, it is classified as a nap." Without it a
/// short tail fragment can be picked as "last night", and then every figure
/// on the screen is a sub-hour value — which reads as a formatting bug.
const napThreshold = Duration(hours: 1);

/// How large a gap between segments still counts as the same night.
///
/// The band emits one segment roughly every two hours while asleep, and
/// segments are contiguous — each starts where the previous ended. So a gap
/// only appears when a segment is missing, and ONE dropped segment produces a
/// ~120-minute hole.
///
/// This was set to 90 minutes, which meant a single dropped segment split the
/// night in two and silently reported 5h20m instead of the real 7h29m.
/// 150 minutes absorbs one missing segment while still separating a genuine
/// nap taken hours later.
const sameNightGap = Duration(minutes: 150);

/// Assemble 0x53 segments into nights.
List<SleepNight> buildNights(List<j.SleepSegment> segments) {
  if (segments.isEmpty) return const [];
  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));

  final groups = <List<j.SleepSegment>>[];
  for (final s in sorted) {
    if (groups.isEmpty ||
        s.start.difference(groups.last.last.end) > sameNightGap) {
      groups.add([s]);
    } else {
      groups.last.add(s);
    }
  }

  return groups.map((g) {
    final blocks = <StageBlock>[];
    final mins = <int, double>{};
    for (final seg in g) {
      final per = seg.minutesPerSlot;
      var t = seg.start;
      for (final code in seg.stages) {
        final next = t.add(Duration(seconds: (per * 60).round()));
        // Merge consecutive slots of the same stage so the hypnogram draws
        // blocks rather than a comb of identical bars.
        if (blocks.isNotEmpty &&
            blocks.last.code == code &&
            blocks.last.end == t) {
          blocks[blocks.length - 1] =
              StageBlock(blocks.last.start, next, code);
        } else {
          blocks.add(StageBlock(t, next, code));
        }
        mins[code] = (mins[code] ?? 0) + per;
        t = next;
      }
    }
    return SleepNight(g.first.start, g.last.end, blocks, mins);
  }).toList();
}

/// Groups long enough to count as a night's sleep.
List<SleepNight> nightsOnly(List<SleepNight> all) =>
    all.where((n) => n.inBed >= napThreshold).toList();

/// Everything shorter — shown separately, as the vendor does.
List<SleepNight> napsOnly(List<SleepNight> all) =>
    all.where((n) => n.inBed < napThreshold).toList();

/// Format a duration the way a sleep screen should read it.
///
/// Always shows hours once there is at least one, so a 449-minute night reads
/// "7h 29m" and never "449m". Sub-hour values stay in plain minutes, which is
/// what latency and short awake periods want.
String formatHm(Duration d) {
  final total = d.inMinutes;
  if (total <= 0) return '0m';
  final h = total ~/ 60;
  final m = total % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

// ------------------------------------------------------------- ratings

Rating rateSleepingHr(double bpm) => switch (bpm) {
      < 45 => Rating.good,
      < 65 => Rating.optimal,
      < 72 => Rating.good,
      _ => Rating.needsAttention,
    };

Rating rateSpo2(double pct) => switch (pct) {
      >= 95 => Rating.optimal,
      >= 90 => Rating.good,
      _ => Rating.needsAttention,
    };

Rating rateHrv(double ms) => switch (ms) {
      >= 50 => Rating.optimal,
      >= 30 => Rating.good,
      _ => Rating.needsAttention,
    };

/// Summarise a metric over the night, with a rating for the average and the
/// lowest reading — the shape the vendor's sleep screen uses.
MetricSummary? summarise(
  List<Sample> samples,
  DateTime start,
  DateTime end,
  Rating Function(double) rate, {
  bool lowIsBad = true,
}) {
  final inWindow = samples
      .where((s) => !s.at.isBefore(start) && !s.at.isAfter(end))
      .map((s) => s.value)
      .toList();
  if (inWindow.isEmpty) return null;
  final avg = inWindow.reduce((a, b) => a + b) / inWindow.length;
  final lo = inWindow.reduce(math.min);
  final hi = inWindow.reduce(math.max);
  return MetricSummary(
    avg,
    lo,
    hi,
    rate(avg),
    // For heart rate a low value overnight is good, so the "lowest" tile is
    // rated on its own merits rather than by the same threshold direction.
    lowIsBad ? rate(lo) : Rating.optimal,
  );
}
