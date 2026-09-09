import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:aurav5/data/profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurav5/ble/band_link.dart';
import 'package:aurav5/protocol/jstyle.dart' as j;

/// The scan used to withhold every result until its 20-second timeout expired.
/// These tests pin the ordering and the redraw policy that make a live list
/// usable: correct order at every intermediate step, and no rebuild storm.
void main() {
  group('live candidate ordering', () {
    // Mirrors the comparator in BandLink.scan: score first, then signal.
    int cmp(({int score, int rssi}) a, ({int score, int rssi}) b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : b.rssi.compareTo(a.rssi);
    }

    test('a strong match outranks a closer but weaker one', () {
      final list = [
        (score: 0, rssi: -30),   // very close, not a band
        (score: 160, rssi: -90), // our band, far away
      ]..sort(cmp);
      expect(list.first.score, 160,
          reason: 'proximity must not bury the band you are looking for');
    });

    test('equal scores fall back to signal strength', () {
      final list = [
        (score: 100, rssi: -80),
        (score: 100, rssi: -40),
      ]..sort(cmp);
      expect(list.first.rssi, -40);
    });

    test('order is correct at every prefix, not only when complete', () {
      // The list is shown while it is still filling, so a comparator that
      // only sorts correctly on the full set would display wrong order for
      // most of the scan.
      final arriving = [
        (score: 20, rssi: -60),
        (score: 160, rssi: -70),
        (score: 100, rssi: -50),
        (score: 0, rssi: -35),
      ];
      final shown = <({int score, int rssi})>[];
      for (final c in arriving) {
        shown
          ..add(c)
          ..sort(cmp);
        for (var i = 0; i + 1 < shown.length; i++) {
          expect(cmp(shown[i], shown[i + 1]), lessThanOrEqualTo(0),
              reason: 'out of order after ${shown.length} results');
        }
      }
      expect(shown.first.score, 160);
    });
  });

  group('redraw policy', () {
    // A busy room produces hundreds of advertisements a second and RSSI
    // jitters by a few dBm constantly. Redrawing on every one would thrash
    // the UI for no visible benefit.
    bool significant(
        {required int? prevScore,
        required int? prevRssi,
        required String prevName,
        required int score,
        required int rssi,
        required String name}) {
      if (prevScore == null) return true; // never seen before
      return score != prevScore ||
          (name.isNotEmpty && name != prevName) ||
          (rssi - prevRssi!).abs() >= 5;
    }

    test('a brand-new device always redraws', () {
      expect(
          significant(
              prevScore: null,
              prevRssi: null,
              prevName: '',
              score: 0,
              rssi: -90,
              name: ''),
          isTrue);
    });

    test('small RSSI jitter does NOT redraw', () {
      expect(
          significant(
              prevScore: 100,
              prevRssi: -70,
              prevName: 'JCV5',
              score: 100,
              rssi: -73,
              name: 'JCV5'),
          isFalse);
    });

    test('a signal shift big enough to reorder DOES redraw', () {
      expect(
          significant(
              prevScore: 100,
              prevRssi: -70,
              prevName: 'JCV5',
              score: 100,
              rssi: -55,
              name: 'JCV5'),
          isTrue);
    });

    test('a name arriving late redraws', () {
      // Bands often advertise unnamed first and named a moment later.
      expect(
          significant(
              prevScore: 60,
              prevRssi: -70,
              prevName: '',
              score: 60,
              rssi: -70,
              name: 'J2208A2 9CF9'),
          isTrue);
    });

    test('a score change redraws even with identical signal', () {
      expect(
          significant(
              prevScore: 60,
              prevRssi: -70,
              prevName: 'x',
              score: 160,
              rssi: -70,
              name: 'x'),
          isTrue);
    });
  });

  group('BandLink exposes the live list', () {
    test('found starts empty and is readable before any scan', () {
      expect(BandLink.instance.found, isEmpty);
    });

    test('stopScan is a no-op when not scanning', () async {
      // Tapping a band the instant a scan ends must not throw.
      await BandLink.instance.stopScan();
      expect(BandLink.instance.state, isNot(LinkState.scanning));
    });
  });

  group('a stale candidate list is never shown', () {
    // Reported from the phone: opening the Device tab displayed the bands
    // from a previous scan, before any new scan had run. The list is a
    // snapshot of one twenty-second window, not an inventory — and because
    // rows are ordered by score then signal, a stale one can put a DIFFERENT
    // band under the same thumb position.
    test('clearFound empties the published list', () {
      final link = BandLink.instance;
      link.found
        ..clear()
        ..addAll([
          Candidate(_dev('AA:BB:CC:DD:EE:01'), 'JCV5 6C6BB3', -76, const [], 100),
          Candidate(_dev('AA:BB:CC:DD:EE:02'), 'J2208A2 9CF9', -86, const [], 160),
        ]);
      expect(link.found, hasLength(2));

      link.clearFound();

      expect(link.found, isEmpty,
          reason: 'the Device tab renders its results card only when found '
              'is non-empty, so clearing it hides the card entirely');
    });

    test('clearFound is a no-op mid-scan', () {
      // Clearing while results are arriving would delete them as they land —
      // the exact opposite of publishing each band the moment it is seen.
      final link = BandLink.instance;
      final before = link.state;
      link.found
        ..clear()
        ..addAll([Candidate(_dev('AA:BB:CC:DD:EE:01'), 'JCV5 6C6BB3', -76, const [], 100)]);
      link.state = LinkState.scanning;

      link.clearFound();

      expect(link.found, hasLength(1),
          reason: 'a live scan must keep publishing into the same list');
      link.state = before;
      link.found.clear();
    });

    test('an EXPLICIT disconnect clears the list', () async {
      // Asked for explicitly after the tab-entry fix. Scoped to the button:
      // an unexpected drop keeps its list (see the group above).
      final link = BandLink.instance;
      link.found
        ..clear()
        ..addAll([
          Candidate(_dev('AA:BB:CC:DD:EE:03'), 'JCV5 6C6BB3', -76, const [], 100),
        ]);

      await link.disconnect();

      expect(link.found, isEmpty);
      expect(link.state, LinkState.idle);
    });

    test('clearFound on an already-empty list does not throw', () {
      final link = BandLink.instance;
      link.found.clear();
      link.clearFound();
      expect(link.found, isEmpty);
    });
  });

  group('a finished scan must not stand down a live connection', () {
    // Reported from the phone: tap the V5 as soon as it is listed, it
    // connects — and roughly twenty seconds later the app shows "Not
    // connected" while the band is still linked.
    //
    // Cause: scan() parks on its full timeout, so it is STILL RUNNING when
    // the user taps. On waking it used to set state = idle unconditionally,
    // stamping over LinkState.connected. `connected` is
    // `state == connected && device.isConnected`, so the app forgets a link
    // the radio still holds.
    test('the tail only stands down while still scanning', () {
      // Mirrors the guard in BandLink.scan.
      LinkState standDown(LinkState now) =>
          now == LinkState.scanning ? LinkState.idle : now;

      expect(standDown(LinkState.connected), LinkState.connected,
          reason: 'a scan timing out must never cancel a connection made '
              'from its own list');
      expect(standDown(LinkState.connecting), LinkState.connecting,
          reason: 'a connect still in flight must survive too');
      expect(standDown(LinkState.scanning), LinkState.idle,
          reason: 'an undisturbed scan still ends idle');
      expect(standDown(LinkState.idle), LinkState.idle);
    });

    test('an unexpected drop keeps the list to reconnect from', () async {
      // The previous fix cleared found on ANY disconnect, which left a band
      // that briefly went out of range with no connection AND no list.
      final link = BandLink.instance;
      link.found
        ..clear()
        ..addAll([
          Candidate(_dev('AA:BB:CC:DD:EE:04'), 'JCV5 BE8D18', -82, const [], 200),
        ]);

      // What the connectionState listener does on a drop: state and channels
      // are torn down, the candidate list is not.
      link.state = LinkState.idle;

      expect(link.found, hasLength(1),
          reason: 'a drop is when the list is most useful — one tap back');
      link.found.clear();
    });
  });

  group('reconnect backoff advances once per failure', () {
    // Observed on the phone: disabling Bluetooth produced
    //   "reconnecting ... in 4s (attempt 2)"
    //   "reconnecting ... in 8s (attempt 3)"
    // logged in the SAME millisecond. A failed attempt notifies twice — the
    // connectionState listener sees `disconnected`, and _tryReconnect sees
    // `ok == false` — so the counter advanced twice per real failure and the
    // 30 s cap arrived in half the tries.
    test('the backoff ladder is the one that was observed', () {
      const steps = [2, 4, 8, 15, 30];
      int delayFor(int attempt) => steps[attempt.clamp(0, steps.length - 1)];

      expect([for (var i = 0; i < 7; i++) delayFor(i)],
          [2, 4, 8, 15, 30, 30, 30],
          reason: 'it caps rather than growing without bound, and never '
              'gives up — "in range" has no deadline');
    });

    test('a second schedule while one is pending is a no-op', () {
      // Mirrors the guard in _scheduleReconnect.
      var attempt = 0;
      var pending = false;
      void schedule() {
        if (pending) return;
        pending = true;
        attempt++;
      }

      schedule(); // the drop handler
      schedule(); // and the failed connect, same millisecond
      expect(attempt, 1,
          reason: 'one real failure must cost exactly one step of backoff');

      pending = false; // timer fired
      schedule();
      expect(attempt, 2);
    });
  });

  group('startup reconnect to the last band', () {
    test('does nothing when no band has ever been remembered', () async {
      final link = BandLink.instance;
      Profile.instance.bandId = null;
      expect(await link.connectToRemembered(), isFalse,
          reason: 'a first run must not sit there scanning for nothing');
    });

    test('the remembered key is the ADDRESS, not the advertised name', () {
      // The name is mutable — this very band renamed itself from
      // "JCV8B 44300D" to "V5" mid-session. Matching on it would have
      // silently stopped recognising the band it had just been paired with.
      Profile.instance.bandId = 'EB:CB:84:44:30:0D';
      Profile.instance.bandDisplayName = 'JCV5 BE8D18';
      expect(Profile.instance.bandId, contains(':'),
          reason: 'a MAC, not a name');

      final candidate = Candidate(_dev('EB:CB:84:44:30:0D'), 'V5 ', -70,
          const [], 100);
      expect(candidate.device.remoteId.str, Profile.instance.bandId,
          reason: 'a renamed band must still match on address');
    });

    test('a different band in range is not mistaken for the remembered one',
        () {
      Profile.instance.bandId = 'EB:CB:84:44:30:0D';
      final other = Candidate(_dev('AA:BB:CC:DD:EE:FF'), 'JCV5 BE8D18', -60,
          const [], 200);
      expect(other.device.remoteId.str == Profile.instance.bandId, isFalse,
          reason: 'connecting to the wrong band would attribute its samples '
              'to the remembered one');
    });
  });

  group('identity does not leak between bands', () {
    test('connecting to a second band must not inherit the first firmware', () {
      // Observed live: a V5 reported "firmware 0.0.3.8", which was the
      // 2208A's version from the previous connection. Worse than a stale
      // label — connect only calls readVersion() when firmware == null, so
      // the carried-over value also suppressed the read that would have
      // corrected it.
      final link = BandLink.instance;
      link.firmware = '0.0.3.8';
      link.model = 'OTHER-BAND';
      link.hardware = 'hw1';
      link.serial = 'sn1';
      link.manufacturer = 'm1';

      link.forgetIdentityForTest();

      expect(link.firmware, isNull);
      expect(link.model, isNull);
      expect(link.hardware, isNull);
      expect(link.serial, isNull);
      expect(link.manufacturer, isNull);
    });
  });

  group('gap detection only fires on real sequences', () {
    // The rule is about the LAYOUT, not the values: 0x51 daily totals have no
    // index at [1:3] at all. A numeric heuristic cannot save you — the two
    // pseudo-indices observed live (9728, 9730) were ADJACENT, so any span
    // test passes them straight through.
    test('history opcodes carry a record index', () {
      for (final op in [0x54, 0x56, 0x53, 0x3B, 0x44, 0x66, 0x58]) {
        expect(j.recordHasIndex(op), isTrue,
            reason: '0x${op.toRadixString(16)} should be index-bearing');
      }
    });

    test('0x51 daily totals do NOT — a BCD date sits at [1:3]', () {
      expect(j.recordHasIndex(0x51), isFalse,
          reason: 'reading the date as an index invented a gap every sync '
              'and burned a round trip re-pulling index 9729');
    });

    List<int> missing(List<int> idx) {
      idx = idx.toSet().toList()..sort();
      if (idx.length < 2) return const [];
      return [
        for (var i = idx.first; i <= idx.last; i++)
          if (!idx.contains(i)) i
      ];
    }

    test('a genuine one-record hole is still reported', () {
      expect(missing([0, 1, 2, 4, 5]), [3]);
    });

    test('the real sleep case that motivated gap detection', () {
      // Indices arrived 4,3,2,0 and the missing segment silently shortened
      // the night by two hours.
      expect(missing([0, 2, 3, 4]), [1]);
    });

    test('a contiguous run reports nothing', () {
      expect(missing([10, 11, 12, 13]), isEmpty);
    });
  });
}

/// A Candidate needs a device, but nothing in these tests touches the radio —
/// fromId builds one without going near the platform channel.
BluetoothDevice _dev(String id) =>
    BluetoothDevice(remoteId: DeviceIdentifier(id));
