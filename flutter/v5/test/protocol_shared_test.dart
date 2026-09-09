import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// Protocol features shared across all three band apps, ported from the
/// 2208A work. Kept in a file of their own so the per-band findings tests
/// stay about that band.
void main() {
  group('firmware version (0x27)', () {
    test('nibble-hex decodes as decimal digits, not as integers', () {
      // 0x10 is sixteen read as an integer and TEN read as nibble-hex. Any
      // component reaching 10 is where the two readings diverge.
      expect(j.parseVersion([0x27, 0x01, 0x02, 0x00, 0x08]), '1.2.0.8');
      expect(j.parseVersion([0x27, 0x10, 0x00, 0x00, 0x01]), '10.0.0.1');
    });

    test('a blank version reads as null, not "0.0.0.0"', () {
      expect(j.parseVersion([0x27, 0, 0, 0, 0]), isNull,
          reason: 'the band saying nothing must leave the field empty rather '
              'than display a fake version');
    });

    test('non-BCD bytes are refused rather than half-decoded', () {
      expect(j.parseVersion([0x27, 0x1A, 0x02, 0x00, 0x08]), isNull);
    });

    test('rejects a reply that is not 0x27, and short frames', () {
      expect(j.parseVersion([0x13, 0x01, 0x02, 0x00, 0x08]), isNull);
      expect(j.parseVersion([0x27, 0x01]), isNull);
    });
  });

  group('background monitoring (0x2A / 0x2B)', () {
    test('parses the schedule read back from the band', () {
      // 2b 02 00 00 23 59 ff 1e 00 01 — heart rate, all day, every 30 min.
      final m = j.parseAutoMonitor(
          [0x2B, 0x02, 0x00, 0x00, 0x23, 0x59, 0xFF, 0x1E, 0x00, 0x01])!;
      expect(m.enabled, isTrue);
      expect(m.window, '00:00-23:59');
      expect(m.weekdayMask, 0xFF);
      expect(m.intervalMinutes, 30);
      expect(m.sensor, j.autoSensorHeartRate);
    });

    test('interval is LE16 MINUTES, not seconds', () {
      final m = j.parseAutoMonitor(
          [0x2B, 0x02, 0x00, 0x00, 0x23, 0x59, 0xFF, 0x05, 0x00, 0x03])!;
      expect(m.intervalMinutes, 5, reason: 'temperature reads every 5 min');
    });

    test('a disabled sensor reads back as disabled', () {
      final m = j.parseAutoMonitor(
          [0x2B, 0x00, 0x00, 0x00, 0x23, 0x59, 0xFF, 0x1E, 0x00, 0x01])!;
      expect(m.enabled, isFalse);
    });

    test('allDay round-trips through the payload', () {
      final m = j.AutoMonitor.allDay(j.autoSensorHeartRate, 5);
      final p = m.toPayload();
      expect(p[0], 2);
      expect(p[5], 0xFF);
      expect(p[6] | (p[7] << 8), 5);
      expect(p[8], j.autoSensorHeartRate);
      final back = j.parseAutoMonitor([0x2B, ...p])!;
      expect(back.enabled, isTrue);
      expect(back.intervalMinutes, 5);
      expect(back.sensor, j.autoSensorHeartRate);
    });

    test('rejects a frame that is not a 0x2B reply', () {
      expect(j.parseAutoMonitor([0x54, 0x02, 0, 0, 0, 0, 0, 0, 0, 1]), isNull);
      expect(j.parseAutoMonitor([0x2B, 0x02]), isNull);
    });
  });

}
