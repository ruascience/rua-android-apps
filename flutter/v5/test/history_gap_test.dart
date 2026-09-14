import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aurav5/ble/band_link.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// A record carrying `index`, shaped so `recordIndex` reads it back.
Uint8List rec(int opcode, int index) =>
    Uint8List.fromList([opcode, index & 0xFF, (index >> 8) & 0xFF, 0, 0, 0]);

void main() {
  final link = BandLink.instance;
  const op = j.opHistHeartRate;

  test('a real hole is reported', () {
    final got = link.missingIndicesForTest(
        [rec(op, 0), rec(op, 1), rec(op, 4), rec(op, 5)], op);
    expect(got, [2, 3]);
  });

  test('a corrupted index is not treated as a 40,000-record gap', () {
    // 16-bit index, one garbled record. Enumerating the span produced a
    // pointless re-pull and a log line tens of thousands of integers long.
    final got = link.missingIndicesForTest(
        [rec(op, 0), rec(op, 1), rec(op, 2), rec(op, 40000)], op);
    expect(got, isEmpty);
  });

  test('holes on both sides of a corrupted index survive', () {
    final got = link.missingIndicesForTest(
        [rec(op, 0), rec(op, 3), rec(op, 40000), rec(op, 40003)], op);
    expect(got, [1, 2, 40001, 40002]);
  });

  test('ranges collapse runs', () {
    expect(BandLink.rangesForTest([12, 13, 14, 15, 44, 51, 52]), '12-15, 44, 51-52');
    expect(BandLink.rangesForTest([7]), '7');
    expect(BandLink.rangesForTest(const []), '');
  });

  test('ranges truncate rather than fill the log card', () {
    final scattered = [for (var i = 0; i < 40; i++) i * 3];
    final s = BandLink.rangesForTest(scattered);
    expect(s, contains('+34 more, 40 total'));
    expect(s.length, lessThan(80));
  });
}
