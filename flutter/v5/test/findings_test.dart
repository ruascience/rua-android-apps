import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/protocol/findings.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// These tests exist to stop this app quietly claiming to know things about
/// the V5 that were only ever measured on a V8.
///
/// That is the specific failure mode worth engineering against here: a wrong
/// record offset does not throw, it returns a plausible heart rate. So the
/// corpus must keep provenance honest, and the app must keep saying
/// "unverified" until something is actually checked on a V5.
void main() {
  group('the corpus is honest about provenance', () {
    test('nothing is marked confirmed until it is measured on a V5', () {
      for (final f in findings) {
        if (f.status == FindingStatus.confirmed) {
          expect(f.provenance, FindingProvenance.v5Hardware,
              reason: '${f.id} claims CONFIRMED but was not measured on a V5');
        }
      }
    });

    test('anything inherited from the V8 is marked assumed or open', () {
      for (final f in findings) {
        if (f.provenance == FindingProvenance.v8Hardware) {
          expect(f.isProvisional, isTrue,
              reason: '${f.id} came from a V8 and must not read as V5 fact');
        }
      }
    });

    test('every provisional finding says how to verify it', () {
      for (final f in provisional) {
        expect(f.howToVerify.length, greaterThan(20),
            reason: '${f.id}: a caveat with no route out of it is just noise');
      }
    });

    test('V5 measurements are now recorded, so the caveat comes down', () {
      // 2026-08-27: read-only probe of band JCV5 6C6BB3 established the GATT
      // layout, frame format, BCD timestamps and three record layouts. The
      // standing "nothing is confirmed" banner is therefore retired — and
      // deliberately, by this test changing, not by accident.
      expect(nothingConfirmedOnV5, isFalse);
      final confirmed =
          findings.where((f) => f.status == FindingStatus.confirmed);
      expect(confirmed.length, greaterThanOrEqualTo(6));
      for (final f in confirmed) {
        expect(f.provenance, FindingProvenance.v5Hardware, reason: f.id);
      }
    });

    test('what the V5 does NOT have is recorded as a confirmed absence', () {
      // An absence is a finding. Without it, an empty screen reads as a bug.
      final f = findings.firstWhere((f) => f.id == 'v5-no-hrv-sleep-temp-spo2');
      expect(f.status, FindingStatus.confirmed);
      expect(f.opcodes, containsAll([0x56, 0x53, 0x3B, 0x44]));
      expect(f.summary, contains('0xFF'));
      // and it must admit the ambiguity rather than over-claiming
      expect(f.evidence.toLowerCase(), contains('cannot distinguish'));
    });

    test('the 0x3E discriminator is marked refuted on this band', () {
      final f = findings.firstWhere((f) => f.id == 'v5-model-string');
      expect(f.status, FindingStatus.refuted);
      expect(f.provenance, FindingProvenance.v5Hardware);
      expect(f.summary, contains('6C6BB3'));
    });

    test('HRV history is recorded as WORKING, after two wrong versions', () {
      // This claim was wrong twice: first "HRV is NOT available", then "on
      // demand only, no background series". Both came from reading 0x56
      // while it happened to be empty. It fills hourly.
      final f = findings.firstWhere((f) => f.id == 'v5-hrv-history-works');
      expect(f.status, FindingStatus.confirmed);
      expect(f.provenance, FindingProvenance.v5Hardware);
      expect(f.opcodes, containsAll([0x28, 0x56]));
      expect(f.correctsSomething, isTrue);
      // and it must carry the zero-field rule, which is the actionable part
      expect(f.summary, contains('ZERO'));
      expect(f.summary.toLowerCase(), contains('never as a value'));
    });

    test('blood pressure carries its own caveat', () {
      final f = findings.firstWhere((f) => f.id == 'v5-blood-pressure');
      expect(f.summary.toLowerCase(), contains('cuff'));
      expect(j.hrProvenance, contains('not a clinical'));
    });

    test('the checksum finding records that the V5 does not validate', () {
      final f = findings.firstWhere((f) => f.id == 'v5-frame-format');
      expect(f.status, FindingStatus.confirmed);
      expect(f.correctsSomething, isTrue,
          reason: 'it overturns the V8 diagnostic that silence means a bad '
              'checksum');
    });

    test('the headline uncertainty is present and open', () {
      final f = findings.firstWhere((f) => f.id == 'v5-unknown');
      expect(f.status, FindingStatus.open);
      expect(f.provenance, FindingProvenance.none);
      expect(f.summary.toLowerCase(), contains('hypothesis'));
    });
  });

  group('every finding is well formed', () {
    test('has id, title, summary and evidence', () {
      for (final f in findings) {
        expect(f.id, isNotEmpty);
        expect(f.title, isNotEmpty, reason: f.id);
        expect(f.summary.length, greaterThan(20), reason: f.id);
        expect(f.evidence, isNotEmpty,
            reason: '${f.id}: a claim without evidence is folklore');
      }
    });

    test('ids are unique', () {
      final ids = findings.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('open findings admit they were not attempted', () {
      final open = findings.where((f) => f.status == FindingStatus.open);
      expect(open, isNotEmpty);
      for (final f in open) {
        expect(f.evidence.toLowerCase(), contains('not attempted'),
            reason: f.id);
      }
    });

    test('every cited opcode exists in the opcode table', () {
      for (final f in findings) {
        for (final op in f.opcodes) {
          expect(j.opsByCode.containsKey(op), isTrue,
              reason: '${f.id} cites 0x${op.toRadixString(16)}');
        }
      }
    });
  });

  group('the V8 raw-PPG result is carried without being claimed of the V5',
      () {
    test('it is assumed, not confirmed, and names the band it came from', () {
      final f = findings.firstWhere((f) => f.id == 'raw-ppg-no-pulse-v8');
      expect(f.status, FindingStatus.assumed);
      expect(f.provenance, FindingProvenance.v8Hardware);
      expect(f.title.toLowerCase(), contains('v8'));
      expect(f.summary.toLowerCase(), contains('never started'),
          reason: 'it must say the V5 stream was not actually captured');
    });

    test('the shipped verdict string says it was not measured here', () {
      expect(j.rawPpgVerdict, contains('NOT ON THIS BAND'));
      expect(j.rawPpgVerdict.toLowerCase(), contains('untested'));
    });

    test('both decoy heart rates are still recorded', () {
      final f = findings.firstWhere((f) => f.id == 'ppg-decoy-numbers');
      expect(f.summary, contains('49'));
      expect(f.summary, contains('161'));
    });
  });

  group('scan targeting suits a V5', () {
    test('v5 is a strong name hint in this build', () {
      expect(j.strongNameHints, contains('v5'));
      expect(j.weakNameHints, isNot(contains('v5')));
    });

    test('v8 is only a weak hint here', () {
      expect(j.weakNameHints, contains('v8'));
    });
  });

  group('lookup helpers', () {
    test('findingsForOpcode surfaces the 0x78 caveat', () {
      expect(findingsForOpcode(0x78).map((f) => f.id),
          contains('raw-ppg-no-pulse-v8'));
    });

    test('provisional is exactly the assumed-plus-open set', () {
      expect(provisional.length,
          findings.where((f) => f.isProvisional).length);
      expect(provisional.every((f) => f.status != FindingStatus.confirmed),
          isTrue);
    });
  });
}
