import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/protocol/jstyle.dart';

/// These vectors are duplicated verbatim in `tools/test_protocol.py`. The
/// prober establishes protocol truth against real hardware and the app ships
/// it, so the two implementations must never drift apart.
void main() {
  group('framing', () {
    test('frame is 16 bytes with a sum checksum over bytes 0..14', () {
      final f = frame(0x54, payload: [0x00]);
      expect(f.length, 16);
      expect(f[0], 0x54);
      var sum = 0;
      for (var i = 0; i < 15; i++) {
        sum += f[i];
      }
      expect(f[15], sum & 0xFF);
      expect(verifyFrame(f), isTrue);
      expect(hex(f).replaceAll(' ', ''),
          '54000000000000000000000000000054');
    });

    test('rejects an oversized payload rather than truncating it', () {
      expect(() => frame(0x54, payload: List.filled(15, 0)),
          throwsArgumentError);
    });

    test('whichChecksum identifies the scheme from a reply', () {
      final f = frame(0x13);
      expect(whichChecksum(f), contains('sum'));
    });
  });

  group('BCD', () {
    test('round-trips', () {
      for (final v in [0, 9, 25, 99]) {
        expect(fromBcd(toBcd(v)), v);
      }
    });
    test('rejects non-BCD nibbles', () {
      expect(looksLikeBcd(0x1A), isFalse);
      expect(looksLikeBcd(0x25), isTrue);
    });
  });

  group('records', () {
    Uint8List rec(int op, List<int> ts, List<int> body) => Uint8List.fromList([
          op,
          0,
          0,
          ...ts.map(toBcd),
          ...body,
        ]);

    test('decodes the shared BCD timestamp', () {
      final r = rec(0x54, [26, 8, 25, 7, 30, 15], List.filled(15, 0));
      expect(recordTime(r), DateTime(2026, 8, 25, 7, 30, 15));
    });

    test('rejects an impossible date instead of rolling it over', () {
      // month 13 — DateTime would happily make this January of the next year
      final r = Uint8List.fromList(
          [0x54, 0, 0, toBcd(26), toBcd(13), toBcd(25), 0, 0, 0]);
      expect(recordTime(r), isNull);
    });

    test('heart rate drops empty slots but keeps real samples', () {
      final r = rec(0x54, [26, 8, 25, 7, 30, 0],
          [72, 74, 0, 71, 0, 72, 74, 0, 71, 0, 72, 74, 0, 71, 0]);
      final parsed = parseHrRecord(r);
      expect(parsed.samples, [72, 74, 71, 72, 74, 71, 72, 74, 71]);
      expect(parsed.time, DateTime(2026, 8, 25, 7, 30));
    });

    test('temperature is uint16 little-endian x 0.1 degC', () {
      final r = rec(0x3B, [26, 8, 25, 3, 0, 0], [364 & 0xFF, 364 >> 8]);
      expect(parseTempRecord(r).celsius, closeTo(36.4, 0.001));
    });

    test('temperature outside body range is rejected, not clamped', () {
      final r = rec(0x3B, [26, 8, 25, 3, 0, 0], [0, 0]);
      expect(parseTempRecord(r).celsius, isNull);
    });

    test('HRV puts heart rate at offset 11, not 10', () {
      final r = rec(0x56, [26, 8, 25, 3, 0, 0], [42, 30, 68, 25, 118, 76]);
      final h = parseHrvRecord(r)!;
      expect(h.hrvMs, 42);
      expect(h.vascularAging, 30);
      expect(h.heartRate, 68);
      expect(h.stress, 25);
      expect(h.systolic, 118);
      expect(h.diastolic, 76);
    });

    test('on-demand reply requires byte[1]==1, not the request 0x04', () {
      expect(parseOnDemand([0x28, 4, 70, 97, 40, 20, 118, 76]), isNull);
      final live = parseOnDemand([0x28, 1, 70, 97, 40, 20, 118, 76])!;
      expect(live.heartRate, 70);
      expect(live.spo2, 97);
    });
  });

  group('record splitting', () {
    final good = Uint8List.fromList([0x44, 0, 0, 0, 0, 0, 0, 0, 0, 97]);

    test('splits an exact multiple', () {
      final buf = Uint8List.fromList([...good, ...good, ...good]);
      final r = splitRecords(buf, 0x44);
      expect(r.records.length, 3);
      expect(r.leftover, isEmpty);
    });

    test('resynchronises past a splice instead of corrupting the rest', () {
      // A blind fixed-stride walk would misalign here and lose both trailing
      // records; anchoring on the opcode costs only the junk.
      final buf = Uint8List.fromList(
          [...good, 0xAA, 0xBB, 0xCC, ...good, ...good]);
      final r = splitRecords(buf, 0x44);
      expect(r.records.length, 3);
    });

    test('an all-zero frame yields NO records, not one of zeros', () {
      // 0x3B answers "nothing stored" on the 2208A with a zero-filled frame
      // rather than the [op, 0xFF] marker. The opcode byte matches, so a
      // naive walk emits a record of zeros and the caller reports "1 record"
      // for an empty history — which is what it did before this guard.
      final zeros = Uint8List.fromList([0x3B, ...List.filled(15, 0)]);
      final r = splitRecords(zeros, 0x3B, stride: 11);
      expect(r.records, isEmpty);
    });

    test('a record with real content after the opcode is still kept', () {
      final one = Uint8List.fromList(
          [0x3B, 0x01, 0x00, 0x26, 0x08, 0x27, 0x0F, 0x00, 0x00, 0x6E, 0x01]);
      expect(splitRecords(one, 0x3B, stride: 11).records.length, 1);
    });


    test('0x53 single 130-byte frame is ONE record, not three plus scraps', () {
      // The SDK documents two sleep shapes: stride 34 (5-min samples) and a
      // single ~130-byte frame (1-min samples). 130 is not a multiple of 34,
      // so the stride walk would emit three bogus records and a remainder —
      // losing the night quietly instead of failing.
      final one = Uint8List.fromList([
        0x53, 0x00, 0x00,
        0x26, 0x08, 0x29, 0x23, 0x30, 0x00, // BCD timestamp
        120, // [9] minutes
        0x00,
        ...List.filled(119, 1), // stage bytes
      ]);
      expect(one.length, 130);
      final r = splitRecords(one, 0x53);
      expect(r.records.length, 1, reason: 'one frame, one record');
      expect(r.records.first.length, 130);
    });

    test('the same frame with a trailing 53 ff still gives one record', () {
      final withEnd = Uint8List.fromList([
        0x53, 0x00, 0x00,
        0x26, 0x08, 0x29, 0x23, 0x30, 0x00,
        120, 0x00,
        ...List.filled(119, 1),
        0x53, 0xFF,
      ]);
      final r = splitRecords(withEnd, 0x53);
      expect(r.records.length, 1);
      expect(r.records.first.length, 130);
    });

    test('stride-34 sleep still splits normally', () {
      // The other shape must keep working — this is what the V8 sends.
      final rec = <int>[
        0x53, 0x00, 0x00,
        0x26, 0x08, 0x29, 0x23, 0x30, 0x00,
        24, 0x00,
        ...List.filled(23, 1),
      ];
      expect(rec.length, 34);
      final buf = Uint8List.fromList([...rec, ...rec]);
      final r = splitRecords(buf, 0x53);
      expect(r.records.length, 2);
    });

    test('carries a partial trailing record forward', () {
      final buf = Uint8List.fromList([...good, ...good.sublist(0, 4)]);
      final r = splitRecords(buf, 0x44);
      expect(r.records.length, 1);
      expect(r.leftover.length, 4);
    });
  });

  group('safety', () {
    test('the conflicted 0x2A opcode is never sweepable', () {
      // One public map reads HRV history from it; the other calls it "set
      // auto-measure schedule". Until hardware settles it, it is a write.
      expect(sweepBlocklist, contains(0x2A));
      expect(opsByCode[0x2A]!.safe, isFalse);
    });

    test('state writes, reset and DFU ranges are blocked', () {
      expect(sweepBlocklist, containsAll([0x01, 0x03, 0x72, 0x70, 0xF0, 0xFF]));
    });

    test('every op marked safe really is a read with no risk note', () {
      for (final o in ops.where((o) => o.safe)) {
        expect(o.reads, isTrue, reason: '${o.name} marked safe but not a read');
        expect(o.risk, isEmpty);
        expect(sweepBlocklist.contains(o.code), isFalse,
            reason: '${o.name} is both safe and blocklisted');
      }
    });

    test('0x64 is a write on this family, not a PPI read', () {
      // The vendor SDK and app both call it social-distance settings; only one
      // third-party client claims PPI. Sending it with a non-zero mode byte
      // overwrites the band's scan settings.
      expect(sweepBlocklist, contains(0x64));
      expect(opsByCode[0x64]!.reads, isFalse);
    });

    test('0x78 raw-PPG start is a write', () {
      expect(sweepBlocklist, contains(0x78));
      expect(opsByCode[0x78]!.reads, isFalse);
    });
  });

  group('history paging', () {
    test('carries the sync mode at [1] and stays a valid 16-byte frame', () {
      final f = historyFrame(opHistHeartRate, mode: syncAll);
      expect(f.length, 16);
      expect(f[1], syncAll);
      expect(verifyFrame(f), isTrue);
    });

    test('BCD cursor lands at [4..9]', () {
      final f = historyFrame(opHistHeartRate,
          cursor: DateTime(2026, 8, 24, 13, 5, 9));
      expect(f.sublist(4, 10),
          [26, 8, 24, 13, 5, 9].map(toBcd).toList());
    });

    test('refuses the delete mode unless asked explicitly', () {
      // 0x99 erases every stored record of this type and sits one keystroke
      // away from 0x00.
      expect(() => historyFrame(opHistHeartRate, mode: syncDelete),
          throwsArgumentError);
      expect(
          historyFrame(opHistHeartRate,
              mode: syncDelete, allowDelete: true)[1],
          0x99);
    });

    test('delete mode is 0x99, not decimal 99', () {
      expect(syncDelete, 0x99);
      expect(syncDelete, isNot(99));
    });

    test('detects end-of-stream without eating normal records', () {
      expect(isStreamEnd([0x54, 0, 0, 1, 2, 0xFF]), isTrue);
      expect(isStreamEnd([0x54, 0xFF]), isTrue);
      expect(isStreamEnd([0x44, 0, 0, 0, 0, 0, 0, 0, 0, 97]), isFalse);
    });

    test('record index is a little-endian uint16 at [1:3]', () {
      expect(recordIndex([0x54, 0x05, 0x00]), 5);
      expect(recordIndex([0x54, 0x01, 0x01]), 257);
    });

    test('models the 50-frame stall', () => expect(streamBatchLimit, 50));
  });

  group('raw PPG', () {
    test('streamed 0x3A samples are 4-byte big-endian', () {
      // Corrected from 3-byte: a bare 0x3A read returns 153 zero bytes, but
      // the frames the band streams are 203 bytes = header + 50 x uint32.
      final f = <int>[0x3A, 0, 0];
      for (final v in [2230358, 2245671, 2262531]) {
        f.addAll([
          (v >> 24) & 0xFF,
          (v >> 16) & 0xFF,
          (v >> 8) & 0xFF,
          v & 0xFF,
        ]);
      }
      expect(parseRawPpg(f), [2230358, 2245671, 2262531]);
    });

    test('a real streamed frame yields exactly 50 samples', () {
      // 203 bytes: 3-byte header + 200 bytes of payload.
      final f = <int>[0x3A, 0, 0, ...List.filled(200, 0x11)];
      expect(f.length, 203);
      expect(parseRawPpg(f).length, 50,
          reason: '50 samples per frame at 50 Hz = one frame per second');
    });
  });

  group('skin temperature (0x09 realtime frame)', () {
    // Real frames captured from the band on 2026-08-26.
    List<int> frame(int lo, int hi) => [
          0x09, 0, 0, 0, 0, 0x50, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0x66, lo, hi, 0, 0, 0, 0, 0, 0, 0x75, 0x30,
        ];

    test('decodes the two readings taken from the band', () {
      // 0x014E = 334 -> 33.4 C, and 0x0144 = 324 -> 32.4 C
      expect(parseRealtimeTemperature(frame(0x4e, 0x01)), closeTo(33.4, 0.001));
      expect(parseRealtimeTemperature(frame(0x44, 0x01)), closeTo(32.4, 0.001));
    });

    test('an idle all-zero frame yields nothing, not 0 degrees', () {
      // 0x09 reads all zeros unless a measurement is running. Reporting 0.0 C
      // would look like a real reading.
      expect(parseRealtimeTemperature(List.filled(32, 0)..[0] = 0x09), isNull);
    });

    test('rejects the out-of-range value other firmware puts there', () {
      // Public research saw 0x5332 in these bytes on 2501 firmware, which
      // would decode to 2129.8 C.
      expect(parseRealtimeTemperature(frame(0x32, 0x53)), isNull);
    });

    test('ignores frames that are not 0x09 or are too short', () {
      expect(parseRealtimeTemperature(frame(0x4e, 0x01)..[0] = 0x54), isNull);
      expect(parseRealtimeTemperature([0x09, 0, 0]), isNull);
    });

    test('the frame carries live daily totals, not a heart rate', () {
      // Byte [5] was read as HR and returned a plausible 45 — but it is the
      // low byte of the calorie counter, and the agreement was coincidence.
      final f = <int>[
        0x09,
        0x9e, 0x10, 0x00, 0x00, //  steps    = 4254
        0x2d, 0x32, 0x00, 0x00, //  0.01kcal = 12845 -> 128.45
        0x37, 0x01, 0x00, 0x00, //  dam      = 311   -> 3.11 km
        0x41, 0x09, 0x00, 0x00, //  active s = 2369
        0x0b, 0x00, 0x00, 0x00, 0x00,
        0x50, 0x01, //              temp     = 336   -> 33.6 C
        0, 0, 0, 0, 0, 0, 0x75, 0x30,
      ];
      final d = parseRealtimeTotals(f)!;
      expect(d.steps, 4254);
      expect(d.kcal, closeTo(128.45, 0.001));
      expect(d.km, closeTo(3.11, 0.001));
      expect(d.active.inSeconds, 2369);
      // and the temperature still decodes from the same frame
      expect(parseRealtimeTemperature(f), closeTo(33.6, 0.001));
    });
  });

  group('daily totals (0x51)', () {
    // The exact record read from the band on 2026-08-26.
    final rec = <int>[
      0x51, 0x00, 0x26, 0x08, 0x26, //           opcode, ?, BCD 2026-08-26
      0x94, 0x10, 0x00, 0x00, //                 steps    = 4244
      0x3d, 0x09, 0x00, 0x00, //                 active s = 2365
      0x36, 0x01, 0x00, 0x00, //                 dam      = 310  -> 3.10 km
      0x11, 0x32, 0x00, 0x00, //                 0.01kcal = 12817 -> 128.17
      0x00, 0x00, 0x0b, 0x00, 0x00, 0x00,
    ];

    test('decodes the real record', () {
      final d = parseDailyTotals(rec)!;
      expect(d.day, DateTime(2026, 8, 26));
      expect(d.steps, 4244);
      expect(d.active.inMinutes, 39);
      expect(d.km, closeTo(3.10, 0.001));
      expect(d.kcal, closeTo(128.17, 0.001));
    });

    test('the scalings reproduce the vendor app ratios', () {
      final d = parseDailyTotals(rec)!;
      // vendor showed 109 steps / 0.08 km / 3.41 kcal on the same device
      expect(d.km * 1000 / d.steps, closeTo(80 / 109, 0.03),
          reason: 'metres per step must match the vendor');
      expect(d.kcal / d.steps, closeTo(3.41 / 109, 0.005),
          reason: 'kcal per step must match the vendor');
    });

    test('rejects a misparse rather than reporting a superhuman day', () {
      final bad = [...rec];
      bad[8] = 0xFF; // steps -> ~4.2 billion
      expect(parseDailyTotals(bad), isNull);
    });

    test('rejects a non-0x51 frame and an impossible date', () {
      expect(parseDailyTotals([...rec]..[0] = 0x54), isNull);
      expect(parseDailyTotals([...rec]..[3] = toBcd(13)), isNull);
    });

    test('0x26 is labelled as settings, not steps', () {
      // It returns a byte-identical frame hours apart, so it cannot be a
      // counter — mislabelling it sent us looking in the wrong place.
      expect(opsByCode[0x26]!.name, contains('NOT_steps'));
    });
  });

  group('discovery heuristics', () {
    test('finds a run of RR intervals', () {
      final rr = <int>[];
      for (final v in [820, 845, 810, 799, 860]) {
        rr.addAll([v & 0xFF, v >> 8]);
      }
      expect(rrRunLength(rr), 5);
    });

    test('masks the response bit before looking up an opcode', () {
      expect(replyOpcode(0xD4), 0x54);
      expect(opName(replyOpcode(0xD4)), 'hist_heart_rate');
    });
  });

  group('hardware-confirmed facts (JCV8B 44300D, fw V0.0.8.8)', () {
    // Real frames captured from the band on 2026-08-26.

    test('battery reply decodes to 100% and its checksum validates', () {
      final d = <int>[
        0x13, 0x64, 0x00, 0x42, 0x99, 0x42, 0x99, 0x64,
        0x64, 0x64, 0, 0, 0, 0, 0, 0x59
      ];
      expect(d[1], 100);
      expect(verifyFrame(d), isTrue);
    });

    test('HR record yields per-sample times 5s apart', () {
      final rec = <int>[
        0x54, 0x01, 0x00, // opcode, index 1
        0x26, 0x08, 0x26, 0x00, 0x04, 0x12, // BCD 2026-08-26 00:04:12
        0x5b, 0x5c, 0x5e, 0x5f, 0x60, 0x62, 0x62,
        0x61, 0x60, 0x5e, 0x5f, 0x5f, 0x5e, 0x60, 0x62,
      ];
      final timed = hrSamplesTimed(rec);
      expect(timed.length, 15);
      expect(timed.first.key, DateTime(2026, 8, 26, 0, 4, 12));
      expect(timed.first.value, 91);
      expect(timed[1].key.difference(timed.first.key).inSeconds, 5);
      // 15 slots x 5s = the observed 75s record period
      expect(hrRecordPeriodSeconds, 75);
    });

    test('empty slots are skipped but still consume their time slot', () {
      // Real record: 82, then two empty slots, then 72...
      final rec = <int>[
        0x54, 0x02, 0x00,
        0x26, 0x08, 0x26, 0x00, 0x01, 0x02,
        0x52, 0x00, 0x00, 0x48, 0x49, 0x48, 0x49, 0x49, 0x50,
        0, 0, 0, 0, 0, 0,
      ];
      final timed = hrSamplesTimed(rec);
      expect(timed.first.value, 82);
      // next real sample sat in slot 3, so it is 15s later, not 5s
      expect(timed[1].value, 72);
      expect(timed[1].key.difference(timed.first.key).inSeconds, 15);
    });

    test('HRV record field order matches the band', () {
      final rec = <int>[
        0x56, 0x01, 0x00,
        0x26, 0x08, 0x25, 0x23, 0x33, 0x30,
        0x28, 0x2f, 0x4a, 0x2f, 0x7b, 0x49,
      ];
      final h = parseHrvRecord(rec)!;
      expect(h.hrvMs, 40);
      expect(h.heartRate, 74);
      expect(h.stress, 47);
      expect(h.systolic, 123);
      expect(h.diastolic, 73);
      expect(h.time, DateTime(2026, 8, 25, 23, 33, 30));
    });

    test('SpO2 comes from 0x66 on this firmware', () {
      final rec = <int>[
        0x66, 0x01, 0x00,
        0x26, 0x08, 0x25, 0x23, 0x31, 0x41, 0x5f,
      ];
      final s = parseSpo2Record(rec);
      expect(s.percent, 95);
      expect(s.time, DateTime(2026, 8, 25, 23, 31, 41));
    });

    test('[opcode,0xFF] means nothing stored / end of stream', () {
      expect(isNothingHere([0x3B, 0xFF]), isTrue);
      expect(isStreamEnd([0x54, 0xFF]), isTrue);
      expect(isNothingHere([0x66, 0x01, 0x00]), isFalse);
    });

    test('bit 7 on a reply is an error flag, not data', () {
      // 0x02 sent with a bad checksum came back as 0x82 with an empty payload.
      expect(replyOpcode(0x82), 0x02);
      expect(0x82 & errorBit, errorBit);
    });
  });
}
