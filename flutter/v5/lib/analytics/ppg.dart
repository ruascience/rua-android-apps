/// Raw-PPG waveform analysis — and the guard that stops us inventing a pulse.
///
/// This is the Dart half of a parity pair with `_rr_from_ppg` / `_is_periodic`
/// in `tools/probe.py`. The algorithm is deliberately identical: the prober
/// establishes protocol truth against real hardware and the app ships it, so
/// the two must never drift apart.
///
/// ## Why a gate exists at all
///
/// A threshold detector fires happily on noise. Run one over the JCVital's
/// `0x3A` stream and it "finds" ~160 bpm — every time, from a signal that
/// provably contains no heartbeat. That number is an artefact, and it is
/// exactly the kind of plausible-looking wrong answer that ends up in a
/// health UI.
///
/// So detection is gated on **periodicity**, not amplitude: unless the
/// waveform autocorrelates at a lag inside the plausible pulse band, whatever
/// the detector found is rejected and [PpgAnalysis.hasPulse] is false.
///
/// ## Verdict on this hardware
///
/// The JCVital `0x78` -> `0x3A` stream does NOT carry a pulse. See
/// [rawPpgVerdict] and PROTOCOL.md §6.2.3a. Heart rate and HRV come from the
/// band's own `0x56` history and `0x28` on-demand measurement instead. This
/// analyser is kept because it is what *proves* the stream is unusable, and
/// it is regression-tested against the real capture.
library;

import 'dart:math' as math;

import '../protocol/jstyle.dart' show rawPpgVerdict;

/// What an attempt to read beats out of a waveform actually yielded.
class PpgAnalysis {
  /// True only if the waveform is genuinely periodic in the pulse band.
  ///
  /// When false every other numeric field is null: there is no honest heart
  /// rate to report, so none is reported.
  final bool hasPulse;

  /// Beat-to-beat intervals in milliseconds. Empty unless [hasPulse].
  final List<int> rrIntervalsMs;

  /// Mean heart rate in bpm, or null when there is no pulse.
  final double? bpm;

  /// RMSSD in milliseconds — real HRV, derived from beats. Null without a
  /// pulse, and null with fewer than three intervals to difference.
  final double? rmssdMs;

  /// Plain-language explanation, suitable for showing to a human.
  final String reason;

  const PpgAnalysis({
    required this.hasPulse,
    required this.rrIntervalsMs,
    required this.bpm,
    required this.rmssdMs,
    required this.reason,
  });

  const PpgAnalysis.noPulse(this.reason)
      : hasPulse = false,
        rrIntervalsMs = const [],
        bpm = null,
        rmssdMs = null;
}

/// Lowest and highest pulse rates we will entertain, in bpm.
///
/// Anything outside this is not a resting human heart, so a "period" found
/// there is noise by definition.
const ppgMinBpm = 40;
const ppgMaxBpm = 180;

/// Minimum autocorrelation at the candidate period before we believe it.
const ppgPeriodicityThreshold = 0.3;

/// How far the threshold detector's rate may differ from the waveform's
/// autocorrelation period before we refuse to report a rate at all.
const ppgRateAgreementTolerance = 0.20;

/// Shortest lag examined. Structure between here and the pulse band is the
/// signature of a decode artefact — see GUARD 1 in [hasPulsePeriodicity].
const ppgArtefactFloorLag = 3;

/// Analyse a raw-PPG waveform for beats.
///
/// [samples] are the values from [parseRawPpg], concatenated across frames.
/// Returns a verdict that is honest about failure — see [PpgAnalysis.hasPulse].
PpgAnalysis analysePpg(List<int> samples, {double sampleRateHz = 50.0}) {
  final fs = sampleRateHz;
  if (samples.isEmpty) return const PpgAnalysis.noPulse('no samples');
  if (samples.every((v) => v == 0)) {
    return const PpgAnalysis.noPulse(
        'every sample is zero — the sensor produced no signal');
  }
  // Keep zeros in the series. They are dropouts, not absences: dropping them
  // silently compresses the time axis, so a beat index no longer maps to a
  // real instant and every derived interval is wrong.
  final xs = [for (final v in samples) v.toDouble()];
  if (xs.length < fs * 3) {
    return PpgAnalysis.noPulse('only ${(xs.length / fs).toStringAsFixed(1)} s '
        'of signal; need at least 3 s');
  }

  // Detrend against a ~1 s moving average to strip baseline wander.
  final base = _movingAverage(xs, fs.round());
  final det = _winsorize([for (var i = 0; i < xs.length; i++) xs[i] - base[i]]);

  // Robust amplitude reference. NOT the global maximum: a single transient
  // sets an unreachable threshold and silences the whole trace. Our own
  // capture does exactly that — the first 20 samples sit near 1.79M against a
  // ~340k body, and a max-based threshold found 2 crossings in 31 seconds.
  final positives = [for (final v in det) if (v > 0) v]..sort();
  if (positives.isEmpty) {
    return const PpgAnalysis.noPulse('waveform has no positive excursion');
  }
  final peak = positives[(positives.length * 0.95).floor()
      .clamp(0, positives.length - 1)];
  if (peak <= 0) {
    return const PpgAnalysis.noPulse('waveform has no positive excursion');
  }

  // Threshold-crossing detector with a refractory period.
  final thresh = peak * 0.35;
  final refractory = (fs * 0.3).round(); // 300 ms -> at most 200 bpm
  final beats = <int>[];
  var i = 1;
  while (i < det.length) {
    if (det[i - 1] < thresh && thresh <= det[i]) {
      beats.add(i);
      i += refractory;
    } else {
      i++;
    }
  }

  final rr = <int>[];
  for (var k = 0; k + 1 < beats.length; k++) {
    final ms = ((beats[k + 1] - beats[k]) * 1000 / fs).round();
    if (ms >= 300 && ms <= 2000) rr.add(ms);
  }

  // THE GATE. Everything above will happily produce intervals from noise.
  final lag = pulsePeriodLag(det, sampleRateHz: fs);
  if (lag == null) {
    return const PpgAnalysis.noPulse(
        'no pulse in this waveform — the autocorrelation has no local maximum '
        'in the $ppgMinBpm-$ppgMaxBpm bpm band, i.e. this is drift, not beats');
  }
  if (rr.isEmpty) {
    return const PpgAnalysis.noPulse('no clean beats detected');
  }

  final meanRr = rr.reduce((a, b) => a + b) / rr.length;
  final bpmFromBeats = 60000 / meanRr;
  final bpmFromPeriod = 60 * fs / lag;

  // CROSS-CHECK. The detector and the autocorrelation measure the rate by
  // independent means; a real pulse makes them agree. When they disagree the
  // detector has locked onto something else, and the honest answer is that we
  // do not know the rate — not an average of two numbers, one of which is
  // wrong.
  final disagreement =
      (bpmFromBeats - bpmFromPeriod).abs() / bpmFromPeriod;
  if (disagreement > ppgRateAgreementTolerance) {
    return PpgAnalysis.noPulse(
        'beat detector says ${bpmFromBeats.toStringAsFixed(0)} bpm but the '
        'waveform period says ${bpmFromPeriod.toStringAsFixed(0)} bpm; they '
        'disagree by ${(disagreement * 100).toStringAsFixed(0)}%, so the rate '
        'is not trustworthy');
  }

  double? rmssd;
  if (rr.length > 2) {
    var sum = 0.0;
    for (var k = 0; k + 1 < rr.length; k++) {
      final d = (rr[k + 1] - rr[k]).toDouble();
      sum += d * d;
    }
    rmssd = math.sqrt(sum / (rr.length - 1));
  }

  return PpgAnalysis(
    hasPulse: true,
    rrIntervalsMs: List.unmodifiable(rr),
    bpm: bpmFromBeats,
    rmssdMs: rmssd,
    reason: '${rr.length} beat-to-beat intervals; detector '
        '${bpmFromBeats.toStringAsFixed(0)} bpm and period '
        '${bpmFromPeriod.toStringAsFixed(0)} bpm agree',
  );
}

/// True only if [det] autocorrelates at a lag in the [ppgMinBpm]-[ppgMaxBpm]
/// band.
///
/// A real pulse produces a local MAXIMUM in the autocorrelation at its period,
/// and again at multiples of it. Slow drift produces a curve that falls
/// monotonically and peaks nowhere. That is precisely the difference we kept
/// seeing on the JCVital's `0x3A` stream — measured r fell smoothly from
/// +0.982 at 80 ms to 0.000 at 1680 ms with no maximum in between — so it is
/// the test.
bool hasPulsePeriodicity(List<double> det, {double sampleRateHz = 50.0}) =>
    pulsePeriodLag(det, sampleRateHz: sampleRateHz) != null;

/// The lag of the pulse period in samples, or null when there is no pulse.
///
/// Returns the STRONGEST in-band local maximum rather than the first one
/// found, so a weak sidelobe cannot pre-empt the true period.
int? pulsePeriodLag(List<double> det, {double sampleRateHz = 50.0}) {
  final n = det.length;
  final lo = (sampleRateHz * 60 / ppgMaxBpm).floor();
  final hi = (sampleRateHz * 60 / ppgMinBpm).floor();
  if (lo < 3 || n < hi * 2) return null;

  var mean = 0.0;
  for (final v in det) {
    mean += v;
  }
  mean /= n;
  final c = [for (final v in det) v - mean];

  var variance = 0.0;
  for (final v in c) {
    variance += v * v;
  }
  if (variance <= 0) return null;

  // Autocorrelate from well below the pulse band, because what lies below it
  // is exactly what tells a pulse apart from a decode artefact.
  // Autocorrelate one lag PAST the band so the last in-band lag can still be
  // tested for being a local maximum.
  final top = math.min(hi + 1, n ~/ 2 - 1);
  if (top <= ppgArtefactFloorLag) return null;
  final r = <int, double>{};
  for (var lag = ppgArtefactFloorLag; lag <= top; lag++) {
    var acc = 0.0;
    for (var k = 0; k + lag < n; k++) {
      acc += c[k] * c[k + lag];
    }
    r[lag] = acc / variance;
  }

  bool isLocalMax(int lag) =>
      r.containsKey(lag - 1) &&
      r.containsKey(lag + 1) &&
      r[lag]! > r[lag - 1]! &&
      r[lag]! > r[lag + 1]!;

  // GUARD 1 — sub-band structure means a decode artefact, not a heartbeat.
  //
  // A pulse is the FASTEST periodicity in a PPG trace: below its period the
  // autocorrelation just falls away smoothly. Byte-misaligned decoding, by
  // contrast, imposes a short artificial period (slicing 4-byte samples as
  // 3-byte repeats every 4 samples, since lcm(3,4)=12 bytes) whose harmonics
  // land inside the pulse band and mimic a plausible rate. Measured on the
  // real capture misdecoded that way: local maxima at lags 4, 8, 12 and a
  // harmonic at lag 16 with r=+0.367 — enough to pass a naive gate and
  // "prove" 161 bpm. So any local maximum below the band disqualifies it.
  for (var lag = ppgArtefactFloorLag + 1; lag < lo; lag++) {
    if (isLocalMax(lag) && r[lag]! > ppgPeriodicityThreshold) return null;
  }

  // GUARD 2 — a genuine period shows as a local maximum inside the band.
  // Take the STRONGEST such peak, not the first: the first is whichever has
  // the shortest lag, which is not necessarily the fundamental.
  int? best;
  for (var lag = lo; lag <= hi && lag < top; lag++) {
    if (isLocalMax(lag) && r[lag]! > ppgPeriodicityThreshold) {
      if (best == null || r[lag]! > r[best]!) best = lag;
    }
  }
  return best;
}

/// Clamp extreme excursions to a robust multiple of the typical amplitude.
///
/// Without this, one transient destroys the analysis — not through the
/// detection threshold, which is already robust, but through the VARIANCE
/// that normalises the autocorrelation. A single 40M spike against a 30k
/// pulse, or a dropout to zero against a 2M baseline, makes every genuine
/// correlation vanish into rounding error and the gate reports "no pulse" on
/// a perfectly good trace.
///
/// Both cases are real: the band's AGC settle puts ~20 leading samples near
/// 1.79M against a ~340k body, and BLE dropouts show up as zeros.
List<double> _winsorize(List<double> det, {double k = 3.0}) {
  if (det.isEmpty) return det;
  final mags = [for (final v in det) v.abs()]..sort();
  final scale = mags[(mags.length * 0.95).floor().clamp(0, mags.length - 1)];
  if (scale <= 0) return det;
  final lim = k * scale;
  return [for (final v in det) v.clamp(-lim, lim)];
}

List<double> _movingAverage(List<double> x, int w) {
  if (w < 1) w = 1;
  final out = <double>[];
  var run = 0.0;
  for (var i = 0; i < x.length; i++) {
    run += x[i];
    if (i >= w) run -= x[i - w];
    out.add(run / math.min(i + 1, w));
  }
  return out;
}
