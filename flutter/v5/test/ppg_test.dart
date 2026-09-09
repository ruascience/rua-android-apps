import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/analytics/ppg.dart';
import 'package:aurav5/protocol/jstyle.dart';

/// The real thing: 1550 samples streamed from a worn JCVital Pro V8 with the
/// LEDs driven by 0x28. If a future change ever makes this look like a pulse,
/// either we cracked the stream or we fooled ourselves — and the second is far
/// more likely, so this test exists to make us look.
Map<String, dynamic> _fixture() => jsonDecode(
        File('test/fixtures/ppg_real_0x3a.json').readAsStringSync())
    as Map<String, dynamic>;

List<int> _realSamples() =>
    (_fixture()['samples'] as List).cast<int>();

/// A clean synthetic pulse at [bpm], as a large DC with a small AC ripple —
/// the shape real PPG actually has.
List<int> _syntheticPulse(int bpm,
    {double seconds = 30, double fs = 50, double acFraction = 0.015}) {
  const dc = 2000000.0;
  final n = (seconds * fs).round();
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final phase = 2 * math.pi * (bpm / 60.0) * i / fs;
    // fundamental plus a second harmonic, which is what gives PPG its
    // characteristic asymmetric upstroke
    final ac = math.sin(phase) + 0.3 * math.sin(2 * phase);
    out.add((dc * (1 + acFraction * ac)).round());
  }
  return out;
}

/// Same detrend the analyser uses, so these tests exercise the real shape.
List<double> _detrend(List<int> samples, int w) {
  final xs = [for (final v in samples) if (v != 0) v.toDouble()];
  final base = <double>[];
  var run = 0.0;
  for (var i = 0; i < xs.length; i++) {
    run += xs[i];
    if (i >= w) run -= xs[i - w];
    base.add(run / math.min(i + 1, w));
  }
  return [for (var i = 0; i < xs.length; i++) xs[i] - base[i]];
}

/// A bare threshold detector with no periodicity gate — what we must not ship.
int _ungatedBeatCount(List<double> det, {int refractory = 15}) {
  final thresh = det.reduce(math.max) * 0.35;
  var beats = 0;
  var i = 1;
  while (i < det.length) {
    if (det[i - 1] < thresh && thresh <= det[i]) {
      beats++;
      i += refractory;
    } else {
      i++;
    }
  }
  return beats;
}

void main() {
  group('periodicity gate', () {
    test('accepts a clean 60 bpm pulse and recovers the rate', () {
      final r = analysePpg(_syntheticPulse(60));
      expect(r.hasPulse, isTrue, reason: r.reason);
      expect(r.bpm, closeTo(60, 4));
      expect(r.rrIntervalsMs, isNotEmpty);
    });

    test('recovers a range of plausible resting rates', () {
      for (final bpm in [48, 55, 72, 95]) {
        final r = analysePpg(_syntheticPulse(bpm));
        expect(r.hasPulse, isTrue, reason: '$bpm bpm: ${r.reason}');
        expect(r.bpm, closeTo(bpm.toDouble(), bpm * 0.12),
            reason: 'recovered ${r.bpm} for $bpm bpm');
      }
    });

    test('rejects monotonic drift instead of inventing a heart rate', () {
      final drift = [for (var i = 0; i < 1500; i++) 2000000 + i * 300];
      final r = analysePpg(drift);
      expect(r.hasPulse, isFalse);
      expect(r.bpm, isNull);
      expect(r.rmssdMs, isNull);
      expect(r.rrIntervalsMs, isEmpty);
      expect(r.reason, contains('drift'));
    });

    test('a no-pulse verdict never carries a number', () {
      // The whole point of the gate: no pulse means no bpm, no RMSSD, no
      // intervals. A health UI must not be handed a plausible-looking value.
      for (final s in <List<int>>[
        [for (var i = 0; i < 1500; i++) 2000000 + i * 300],
        List.filled(1500, 0),
        List.filled(10, 2000000),
      ]) {
        final r = analysePpg(s);
        expect(r.hasPulse, isFalse, reason: 'none of these is a pulse');
        expect(r.bpm, isNull);
        expect(r.rmssdMs, isNull);
        expect(r.rrIntervalsMs, isEmpty);
        expect(r.reason, isNotEmpty);
      }
    });

    test('rejects an all-zero stream with a clear reason', () {
      final r = analysePpg(List.filled(1500, 0));
      expect(r.hasPulse, isFalse);
      expect(r.reason, contains('zero'));
    });

    test('rejects a capture too short to judge', () {
      final r = analysePpg(_syntheticPulse(60, seconds: 2));
      expect(r.hasPulse, isFalse);
      expect(r.reason, contains('3 s'));
    });
  });

  group('the real 0x3A capture', () {
    test('is 31 s of 50 Hz data', () {
      final f = _fixture();
      final s = _realSamples();
      expect(s.length, 1550);
      expect(s.length / (f['rate_hz'] as int), closeTo(31.0, 0.1));
    });

    test('is correctly reported as NO pulse', () {
      final r = analysePpg(_realSamples());
      expect(r.hasPulse, isFalse,
          reason: 'the 0x3A stream provably contains no heartbeat; '
              'claiming otherwise means the gate regressed');
      expect(r.bpm, isNull);
      expect(r.rmssdMs, isNull);
    });

    test('an ungated detector invents 49 bpm from it — the gate says no', () {
      // Prove the gate is load-bearing, not decorative. On the correctly
      // decoded stream a bare threshold detector finds 2 crossings, yielding
      // ONE interval and a perfectly plausible-looking "49 bpm" resting rate.
      // It is pure noise.
      final det = _detrend(_realSamples(), 50);
      expect(_ungatedBeatCount(det), greaterThanOrEqualTo(2),
          reason: 'the ungated detector does produce crossings');
      expect(hasPulsePeriodicity(det), isFalse,
          reason: 'but there is no periodicity, so the gate rejects them');
      expect(analysePpg(_realSamples()).bpm, isNull,
          reason: 'and no number reaches the caller');
    });

    test('the gate also catches the 3-byte MISDECODE, which fakes 161 bpm', () {
      // This is the failure that actually bit us. Decoding the same frames as
      // 3-byte samples (the original, wrong reading) produces 109 intervals
      // and a confident 161 bpm — far more convincing than the 49 bpm above,
      // and completely fictional. A decode bug must not become a heart rate.
      final frames = (jsonDecode(
                  File('test/fixtures/ppg_frames_raw.json').readAsStringSync())
              as Map<String, dynamic>)['frames'] as List;
      final wrong = <int>[];
      for (final h in frames.cast<String>()) {
        final b = <int>[];
        for (var i = 0; i < h.length; i += 2) {
          b.add(int.parse(h.substring(i, i + 2), radix: 16));
        }
        final body = b.sublist(3);
        for (var i = 0; i + 2 < body.length; i += 3) {
          wrong.add((body[i] << 16) | (body[i + 1] << 8) | body[i + 2]);
        }
      }
      expect(wrong.length, 2046, reason: '3-byte decode over 31 frames');

      final det = _detrend(wrong, 50);
      expect(_ungatedBeatCount(det), greaterThan(100),
          reason: 'the misdecode yields a very convincing 161 bpm');
      // Note this is NOT caught by periodicity alone — the misdecode really
      // is periodic, at an artificial 4-sample byte-alignment period whose
      // harmonic at lag 16 reaches r=+0.367 inside the pulse band. It is
      // GUARD 1, the sub-band structure check, that rejects it.
      expect(hasPulsePeriodicity(det), isFalse,
          reason: 'sub-band local maxima at lags 4/8/12 give the artefact '
              'away, so the gate rejects it');
      expect(analysePpg(wrong).hasPulse, isFalse);
      expect(analysePpg(wrong).bpm, isNull);
    });
  });

  group('0x3A frame decode', () {
    test('real frames are 203 bytes and yield exactly 50 samples', () {
      // 203 = 3-byte header (3a 00 NN) + 200 bytes of payload.
      final f = <int>[0x3A, 0x00, 0x00, ...List.filled(200, 0x11)];
      expect(f.length, 203);
      expect(parseRawPpg(f).length, 50);
    });

    test('samples are 4-byte big-endian, not 3-byte', () {
      final f = <int>[0x3A, 0x00, 0x01];
      for (final v in [335563, 335170, 320066]) {
        f.addAll([
          (v >> 24) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 8) & 0xFF,
          v & 0xFF,
        ]);
      }
      expect(parseRawPpg(f), [335563, 335170, 320066]);
    });

    test('frame-shape constants are self-consistent', () {
      expect(ppgFrameBytes, 3 + ppgSamplesPerFrame * ppgSampleBytes);
      expect(ppgFrameBytes, isNot(153),
          reason: '153 is the EMPTY bare-read length, not a streamed frame');
    });

    test('isWellFormedPpgFrame accepts a real frame, rejects the bare read', () {
      final real = <int>[0x3A, 0x00, 0x00, ...List.filled(200, 0x11)];
      expect(isWellFormedPpgFrame(real), isTrue);
      // The 153-byte bare read is what misled us into a 3-byte reading.
      final bareRead = <int>[0x3A, 0x00, 0x00, ...List.filled(150, 0)];
      expect(isWellFormedPpgFrame(bareRead), isFalse);
      expect(isWellFormedPpgFrame(const <int>[]), isFalse);
    });

    test('the real capture decodes into the physical range we measured', () {
      final s = _realSamples();
      // 20 AGC-settling samples near 1.79M, then a body around 320-520k.
      final body = s.sublist(20);
      expect(body.reduce(math.min), greaterThan(300000));
      expect(body.reduce(math.max), lessThan(600000));
    });
  });

  group('the verdict is carried in the app', () {
    test('rawPpgVerdict is attributed to the V8, not claimed of the V5', () {
      // In this build the verdict must NOT read as settled fact: it was
      // measured on a different band.
      expect(rawPpgVerdict, contains('NOT ON THIS BAND'));
      expect(rawPpgVerdict, contains('NO pulse'));
      expect(rawPpgVerdict, contains('0x56'));
      expect(rawPpgVerdict.toLowerCase(), contains('untested'));
    });
  });

  group('shared parity contract', () {
    // These cases are specified once, in tools/fixtures/gate_expectations.json,
    // and asserted by BOTH this suite and tools/test_protocol.py. If the Dart
    // and Python gates ever drift apart, one of the two suites fails. That is
    // the only kind of parity claim worth making — the previous one merely
    // said "matches ppg.dart" in a Python test that never touched Dart.
    final spec = jsonDecode(
            File('test/fixtures/gate_expectations.json').readAsStringSync())
        as Map<String, dynamic>;
    final sy = spec['synthetic'] as Map<String, dynamic>;
    final rate = (spec['rate_hz'] as num).toDouble();

    List<int> synthetic(int bpm) {
      final n = ((sy['seconds'] as num) * rate).round();
      final dc = (sy['dc'] as num).toDouble();
      final acF = (sy['ac_fraction'] as num).toDouble();
      final h = (sy['harmonic_fraction'] as num).toDouble();
      return [
        for (var i = 0; i < n; i++)
          () {
            final ph = 2 * math.pi * (bpm / 60.0) * i / rate;
            final ac = math.sin(ph) + h * math.sin(2 * ph);
            return (dc * (1 + acF * ac)).floor();
          }()
      ];
    }

    List<int> build(Map<String, dynamic> c) {
      switch (c['kind'] as String) {
        case 'synthetic_pulse':
          return synthetic(c['bpm'] as int);
        case 'linear_ramp':
          return [
            for (var i = 0; i < (c['count'] as int); i++)
              (c['start'] as int) + i * (c['step'] as int)
          ];
        case 'constant':
          return List.filled(c['count'] as int, c['value'] as int);
        case 'synthetic_pulse_with_transient':
          return [
            ...List.filled(c['prefix_count'] as int, c['prefix_value'] as int),
            ...synthetic(c['bpm'] as int),
          ];
        case 'synthetic_pulse_with_dropouts':
          final out = synthetic(c['bpm'] as int);
          for (var i = c['dropout_start'] as int;
              i < out.length;
              i += c['dropout_stride'] as int) {
            out[i] = 0;
          }
          return out;
        case 'fixture_samples':
          return ((jsonDecode(File('test/fixtures/${c['fixture']}')
                          .readAsStringSync()) as Map<String, dynamic>)['samples']
                  as List)
              .cast<int>();
        case 'fixture_frames_3byte':
          final frames = (jsonDecode(File('test/fixtures/${c['fixture']}')
              .readAsStringSync()) as Map<String, dynamic>)['frames'] as List;
          final out = <int>[];
          for (final h in frames.cast<String>()) {
            final b = <int>[];
            for (var i = 0; i < h.length; i += 2) {
              b.add(int.parse(h.substring(i, i + 2), radix: 16));
            }
            final body = b.sublist(3);
            for (var i = 0; i + 2 < body.length; i += 3) {
              out.add((body[i] << 16) | (body[i + 1] << 8) | body[i + 2]);
            }
          }
          return out;
      }
      throw StateError('unknown kind ${c['kind']}');
    }

    for (final c in (spec['cases'] as List).cast<Map<String, dynamic>>()) {
      test('[${c['name']}] pulse=${c['expect_pulse']}', () {
        final r = analysePpg(build(c), sampleRateHz: rate);
        expect(r.hasPulse, c['expect_pulse'] as bool,
            reason: '${c['why']} — got: ${r.reason}');
        if (c['expect_pulse'] as bool) {
          expect(r.bpm, closeTo((c['bpm'] as int).toDouble(),
              (c['expect_bpm_within'] as num).toDouble()));
        } else {
          expect(r.bpm, isNull);
          expect(r.rmssdMs, isNull);
        }
      });
    }
  });

  group('gaps the audit found', () {
    test('an accepted pulse reports a usable RMSSD', () {
      // rmssdMs was previously asserted only on reject paths, where it is
      // always null — so nothing ever checked it carried a real value.
      final r = analysePpg(_syntheticPulse(60));
      expect(r.hasPulse, isTrue);
      expect(r.rmssdMs, isNotNull);
      expect(r.rmssdMs, greaterThanOrEqualTo(0));
      expect(r.rmssdMs, lessThan(500), reason: 'RMSSD in ms, not nonsense');
      expect(r.rrIntervalsMs.length, greaterThan(2),
          reason: 'RMSSD needs at least 3 intervals to difference');
    });

    test('just above the 3 s minimum, a real pulse is still accepted', () {
      // The reject-below-3 s boundary was tested; the accept-just-above side
      // was not, so the minimum could have been raised silently.
      final r = analysePpg(_syntheticPulse(60, seconds: 3.2));
      expect(r.hasPulse, isTrue, reason: r.reason);
    });

    test('the full frames -> parseRawPpg -> analysePpg path finds no pulse', () {
      // The flagship regression fed pre-decoded integers, so parseRawPpg was
      // not actually on the path it claimed to protect.
      final frames = (jsonDecode(
                  File('test/fixtures/ppg_frames_raw.json').readAsStringSync())
              as Map<String, dynamic>)['frames'] as List;
      final samples = <int>[];
      for (final h in frames.cast<String>()) {
        final b = <int>[];
        for (var i = 0; i < h.length; i += 2) {
          b.add(int.parse(h.substring(i, i + 2), radix: 16));
        }
        expect(isWellFormedPpgFrame(b), isTrue);
        samples.addAll(parseRawPpg(b));
      }
      expect(samples.length, 1550);
      expect(analysePpg(samples).hasPulse, isFalse);
    });

    test('a flat trace has no positive excursion and is rejected', () {
      final r = analysePpg(List.filled(1500, 2000000));
      expect(r.hasPulse, isFalse);
      expect(r.bpm, isNull);
    });

    test('a leading transient no longer silences the whole trace', () {
      // Regression for the confirmed defect: the threshold came from the
      // GLOBAL maximum, so one spike — exactly what the band's AGC settle
      // produces — made the threshold unreachable for every real beat.
      final pulse = _syntheticPulse(60);
      final withSpike = <int>[...List.filled(20, 40000000), ...pulse];
      final r = analysePpg(withSpike);
      expect(r.hasPulse, isTrue,
          reason: 'a 20-sample transient must not hide a 30 s pulse: '
              '${r.reason}');
      expect(r.bpm, closeTo(60, 6));
    });

    test('zeros are kept, so beat timing stays on the real clock', () {
      // Dropping zero samples compressed the time axis and inflated the rate.
      final pulse = _syntheticPulse(60);
      final withDropouts = [...pulse];
      for (var i = 100; i < withDropouts.length; i += 250) {
        withDropouts[i] = 0;
      }
      final r = analysePpg(withDropouts);
      expect(r.hasPulse, isTrue, reason: r.reason);
      expect(r.bpm, closeTo(60, 8),
          reason: 'dropouts must not shift the apparent rate');
    });

    test('a rate the two methods disagree on is refused, not averaged', () {
      // The detector and the autocorrelation measure the rate independently.
      // If they disagree the honest answer is "unknown", not a blend.
      final r = analysePpg(_syntheticPulse(60), sampleRateHz: 25);
      if (!r.hasPulse) {
        expect(r.bpm, isNull);
      } else {
        // If it does accept, the two methods must have agreed.
        expect(r.reason, contains('agree'));
      }
    });

    test('sampleRateHz actually changes the interpretation', () {
      // The parameter was never exercised at any value but the default.
      final pulse = _syntheticPulse(60); // 60 bpm when read at 50 Hz
      final at50 = analysePpg(pulse, sampleRateHz: 50);
      final at100 = analysePpg(pulse, sampleRateHz: 100);
      expect(at50.hasPulse, isTrue);
      if (at100.hasPulse) {
        expect(at100.bpm, greaterThan(at50.bpm! * 1.5),
            reason: 'the same samples read twice as fast are twice the rate');
      }
    });
  });
}
