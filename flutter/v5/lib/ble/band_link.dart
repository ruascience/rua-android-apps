/// BLE transport for J-Style / JCVital bands.
///
/// Deliberately thin: it moves frames, assembles multi-packet history, and
/// keeps a log. It knows nothing about what the bytes mean — that lives in
/// `protocol/jstyle.dart`, so the protocol can be corrected as the prober
/// learns more without touching the transport.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/profile.dart';
import '../protocol/jstyle.dart' as j;

enum LinkState { idle, scanning, connecting, connected }

/// Why a scan or connect could not even be attempted.
///
/// Before this existed all four of these produced the same outcome — an empty
/// result and one line in the activity log — so a refused permission looked
/// exactly like a band that was not there. The user tapped Scan, watched a
/// progress bar, and got nothing, forever, with the explanation three screens
/// down in a monospace debug list.
enum BleBlocker {
  /// Nothing in the way.
  none,

  /// No BLE radio at all. Nothing the user can do; say so and stop offering.
  unsupported,

  /// Bluetooth is switched off. Recoverable, and on Android we can ask.
  adapterOff,

  /// Scan or connect permission refused. Recoverable from the app settings.
  permissionDenied,

  /// Refused twice, or refused with "don't ask again". The in-app prompt will
  /// no longer appear at all, so the ONLY route is the system settings page —
  /// which is exactly the state that has to be said out loud rather than
  /// retried.
  permissionPermanentlyDenied,
}

/// A band seen during a scan, scored by how likely it is to be one of ours.
class Candidate {
  final BluetoothDevice device;
  final String name;
  final int rssi;
  final List<String> services;
  final int score;
  const Candidate(
      this.device, this.name, this.rssi, this.services, this.score);

  bool get strong => score >= 100;
}

/// One notification, timestamped.
class Reply {
  final Uint8List data;
  final DateTime at;
  const Reply(this.data, this.at);

  int get opcode => data.isEmpty ? -1 : j.replyOpcode(data[0]);
  bool get isResponse => data.isNotEmpty && (data[0] & j.responseBit) != 0;
  bool get isEmpty => data.length < 2 || data.skip(1).every((b) => b == 0);
  String get hex => j.hex(data);
}

class BandLink {
  BandLink._();
  static final BandLink instance = BandLink._();

  LinkState state = LinkState.idle;
  BluetoothDevice? device;
  String deviceName = '';
  String? firmware, hardware, model, manufacturer, serial;

  /// Candidates found so far in the CURRENT scan, best first.
  ///
  /// Published as they arrive rather than at the end. A scan runs for twenty
  /// seconds because bands advertise in bursts and a late one is still worth
  /// finding — but the first result usually lands in well under a second, and
  /// making the user stare at a spinner until the timeout expires is just the
  /// list being withheld.
  final List<Candidate> found = [];
  int? batteryPercent;
  int? rssi;

  /// Checksum variant the band has been observed to accept. Starts at the
  /// documented default and is corrected by [detectChecksum].
  String checksum = j.kChecksumSum;

  BluetoothCharacteristic? _write, _notify;
  StreamSubscription? _notifySub, _connSub;

  // ------------------------------------------------------- auto-reconnect
  //
  // A BLE link drops for reasons that have nothing to do with intent: the
  // wrist turns, the phone sleeps, the band's radio duty-cycles. Treating
  // every drop as "the user is done" meant the app sat disconnected until
  // somebody noticed and re-scanned, losing whatever the band logged in the
  // meantime.
  //
  // So a drop is provisional and a Disconnect is final. Only the button sets
  // [_userDisconnected]; everything else gets retried.

  /// Set only by [disconnect] — the user's explicit "stop".
  bool _userDisconnected = false;

  /// The band to go back to. Kept separately from [device], which is cleared
  /// on a drop.
  BluetoothDevice? _reconnectTarget;
  String _reconnectName = '';

  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// True while waiting to retry or retrying, so the UI can say so rather
  /// than showing a bare "Not connected" that looks like nothing is happening.
  bool reconnecting = false;

  /// Called after an automatic reconnect succeeds, so the caller can sync.
  ///
  /// A reconnect without a sync is half a fix: the whole reason the drop
  /// mattered is the data logged while the link was down.
  Future<void> Function()? onReconnected;

  final _events = StreamController<void>.broadcast();
  Stream<void> get changes => _events.stream;
  void _emit() => _events.add(null);

  /// Publish a change event without touching the radio. Tests only.
  @visibleForTesting
  void emitForTest() => _emit();

  final List<String> log = [];
  void _log(String m) {
    final t = DateTime.now();
    // Mirror to the platform log in debug builds. The in-app list is fine
    // when someone is holding the phone, but a BLE session is exactly the
    // situation where you want a transcript you can read from a terminal —
    // scanning, connecting and syncing all fail in ways a screenshot cannot
    // show you.
    if (kDebugMode) debugPrint('[AuraV5] $m');
    log.add('[${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}] $m');
    if (log.length > 500) log.removeRange(0, log.length - 500);
    _emit();
  }

  final List<Reply> replies = [];
  final _replyStream = StreamController<Reply>.broadcast();
  Stream<Reply> get onReply => _replyStream.stream;

  bool get connected =>
      state == LinkState.connected && (device?.isConnected ?? false);

  /// Why the last scan or connect could not start. [BleBlocker.none] once one
  /// has succeeded, so the UI can clear the explanation as soon as it stops
  /// being true.
  BleBlocker blocker = BleBlocker.none;

  /// Everything that must be true before a scan can find anything, checked in
  /// the order the user can act on.
  ///
  /// Returns [BleBlocker.none] when the way is clear. Requests the permission
  /// if it has not been asked for yet — asking is cheap and the system dialog
  /// is a better explanation than anything this app could write.
  Future<BleBlocker> preflight({bool requesting = true}) async {
    try {
      return blocker = await _preflight(requesting);
    } on UnsupportedError {
      // No platform implementation at all — a widget test, or a desktop host.
      // Not a blocker: reporting "this phone has no Bluetooth" on a test
      // harness would be a false statement about the user's hardware, and the
      // scan that follows fails with its own message anyway.
      return blocker = BleBlocker.none;
    } catch (e) {
      // Any other failure asking the platform. Same reasoning: an unknown is
      // not evidence, and the card must only claim what was actually checked.
      _log('could not check Bluetooth readiness: $e');
      return blocker = BleBlocker.none;
    }
  }

  Future<BleBlocker> _preflight(bool requesting) async {
    if (!await FlutterBluePlus.isSupported) {
      _log('this phone has no Bluetooth LE radio');
      return BleBlocker.unsupported;
    }

    // Permission before adapter state: on Android 12+ reading the adapter
    // reliably needs the permission anyway, and asking first means the user
    // answers one dialog rather than being sent to settings and back.
    if (Platform.isAndroid || Platform.isIOS) {
      final needed = Platform.isAndroid
          ? const [Permission.bluetoothScan, Permission.bluetoothConnect]
          : const [Permission.bluetooth];
      for (final p in needed) {
        var status = await p.status;
        if (status.isDenied && requesting) status = await p.request();
        if (status.isPermanentlyDenied) {
          _log('${p.toString().split('.').last} permanently denied — '
              'it can only be granted from the app settings now');
          return BleBlocker.permissionPermanentlyDenied;
        }
        if (!status.isGranted && !status.isLimited) {
          _log('${p.toString().split('.').last} not granted');
          return BleBlocker.permissionDenied;
        }
      }
    }

    final adapter = await _adapterState();
    if (adapter != BluetoothAdapterState.on) {
      _log('Bluetooth is ${adapter.name}');
      return BleBlocker.adapterOff;
    }
    return BleBlocker.none;
  }

  /// Ask Android to switch Bluetooth on. No-op elsewhere — iOS has no such
  /// API, and the card offers different words there.
  Future<void> requestAdapterOn() async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      _log('could not turn Bluetooth on: $e');
    }
    await preflight(requesting: false);
    _emit();
  }

  Future<bool> openPermissionSettings() => openAppSettings();

  // ------------------------------------------------------------- adapter

  /// Wait for a real adapter state.
  ///
  /// `adapterStateNow` is a cached value that stays `unknown` until the
  /// adapter-state stream has emitted at least once, which it has not right
  /// after launch. Treating that as "off" makes Connect fail instantly, every
  /// time, with Bluetooth fully on — and it looks exactly like a permission
  /// bug, which is what makes it expensive.
  Future<BluetoothAdapterState> _adapterState() async {
    var s = FlutterBluePlus.adapterStateNow;
    if (s != BluetoothAdapterState.on) {
      try {
        s = await FlutterBluePlus.adapterState
            .firstWhere((v) => v != BluetoothAdapterState.unknown)
            .timeout(const Duration(seconds: 6));
      } on TimeoutException {
        // fall through with whatever we have
      }
    }
    return s;
  }

  // ---------------------------------------------------------------- scan

  int _score(String name, List<String> services, {String? remoteId}) {
    // A band we have already connected to wins outright, whatever it is
    // currently advertising as. This one renamed itself from "JCV8B 44300D"
    // to "V5" mid-session; matching on the advertised name alone would have
    // demoted it to a weak guess.
    if (remoteId != null &&
        Profile.instance.bandId != null &&
        remoteId == Profile.instance.bandId) {
      return 200;
    }
    final n = name.toLowerCase();
    var s = 0;
    if (j.strongNameHints.any(n.contains)) {
      s += 100;
    } else if (j.weakNameHints.any(n.contains)) {
      s += 20;
    }
    if (services.any(j.serviceCandidates.contains)) s += 60;
    return s;
  }

  /// Scan and return candidates, best first.
  Future<List<Candidate>> scan({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (await preflight() != BleBlocker.none) {
      // The reason is on `blocker`, and DevicePage renders it as a card with
      // the one action that clears it. Returning empty quietly is what made
      // this indistinguishable from "no bands nearby".
      _emit();
      return const [];
    }

    state = LinkState.scanning;
    _log('scanning...');
    _emit();

    final seen = <DeviceIdentifier, Candidate>{};
    found.clear();
    _emit();

    // Re-sorting and rebuilding on every advertisement would thrash the UI:
    // a busy room produces hundreds a second and RSSI jitters constantly.
    // Publish only when the list a human would notice actually changes.
    void publish() {
      found
        ..clear()
        ..addAll(seen.values.toList()
          ..sort((a, b) {
            final c = b.score.compareTo(a.score);
            return c != 0 ? c : b.rssi.compareTo(a.rssi);
          }));
      _emit();
    }

    final sub = FlutterBluePlus.scanResults.listen((results) {
      var significant = false;
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final services = r.advertisementData.serviceUuids
            .map((u) => u.str128.toLowerCase())
            .toList();
        final score = _score(name, services, remoteId: r.device.remoteId.str);
        final prev = seen[r.device.remoteId];

        if (prev == null) {
          // A device we have never seen: always worth showing at once.
          seen[r.device.remoteId] =
              Candidate(r.device, name, r.rssi, services, score);
          significant = true;
          if (score >= 20) {
            _log('found ${name.isEmpty ? "(no name)" : name}  '
                'rssi=${r.rssi}  score=$score');
          }
          continue;
        }

        // Keep the strongest reading, but only redraw when something a
        // person would see has moved: a better name, a changed score, or a
        // signal shift big enough to reorder the list.
        if (score != prev.score ||
            (name.isNotEmpty && name != prev.name) ||
            (r.rssi - prev.rssi).abs() >= 5) {
          significant = true;
        }
        if (r.rssi > prev.rssi || score != prev.score) {
          seen[r.device.remoteId] =
              Candidate(r.device, name.isNotEmpty ? name : prev.name, r.rssi,
                  services, score);
        }
      }
      if (significant) publish();
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await Future.delayed(timeout + const Duration(milliseconds: 300));
    } finally {
      await FlutterBluePlus.stopScan();
      await sub.cancel();
    }

    final out = List<Candidate>.from(found);

    // ⚠ Only stand down if this scan is still the thing that is running.
    //
    // The list is live, so the whole point is that a band can be tapped two
    // seconds in — and THIS future is still parked on its 20-second timeout
    // when that happens. By the time it wakes, the app may be connecting or
    // already connected. Forcing idle here stamps over LinkState.connected:
    // the radio link stays up, but `connected` goes false and the UI drops
    // back to "Not connected" some seconds after a successful connect.
    // Observed on a V5: connect at ~2 s, apparent disconnect at ~20 s.
    if (state == LinkState.scanning) state = LinkState.idle;
    final hits = out.where((c) => c.score >= 20).length;
    _log('scan done — ${out.length} devices, $hits candidate(s)');
    _emit();
    return out;
  }

  // ------------------------------------------------------------- connect

  Future<bool> connect(BluetoothDevice target) async {
    if (state == LinkState.connecting) return false;
    state = LinkState.connecting;
    // Any connect — by hand or automatic — means we are back in business.
    _userDisconnected = false;
    _reconnectTarget = target;
    _reconnectName =
        target.platformName.isEmpty ? target.remoteId.str : target.platformName;
    // Clear the previous band's identity HERE, not only on disconnect:
    // connecting straight from one band to another must not inherit the
    // first one's firmware, model or serial.
    _forgetIdentity();
    _log('connecting to ${target.platformName}...');
    _emit();

    try {
      _connSub?.cancel();
      _connSub = target.connectionState.listen((s) {
        if (s != BluetoothConnectionState.disconnected) return;

        // The stream replays the CURRENT state on listen, so this fires once
        // before the connection has even been attempted. Only react to a drop
        // of a link we actually established.
        if (device != target) return;

        state = LinkState.idle;
        _write = null;
        _notify = null;
        // The candidate list deliberately SURVIVES an unexpected drop. A band
        // going out of range is the moment you most need the list — one tap
        // to reconnect. Clearing here left the user with neither a connection
        // nor anything to reconnect from. Stale entries are still handled:
        // arriving at the Device tab clears them, and so does an explicit
        // Disconnect.
        _log('disconnected');
        _emit();
        // Provisional, not final: retry until the user says otherwise.
        if (!_userDisconnected) _scheduleReconnect();
      });

      // License.nonprofit covers personal use; shipping this commercially
      // needs a paid flutter_blue_plus licence.
      await target.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 25),
        mtu: 512, // requested on Android only; Apple negotiates its own
      );

      final services = await target.discoverServices();
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.str128.toLowerCase();
          if (j.writeCandidates.contains(u) && _write == null) _write = c;
          if (j.notifyCandidates.contains(u) &&
              c.properties.notify &&
              _notify == null) {
            _notify = c;
          }
          if (u == j.disFirmware) firmware = await _readString(c);
          if (u == j.disHardware) hardware = await _readString(c);
          if (u == j.disModel) model = await _readString(c);
          if (u == j.disManufacturer) manufacturer = await _readString(c);
          if (u == j.disSerial) serial = await _readString(c);
          if (u == j.batteryLevel) {
            final v = await c.read();
            if (v.isNotEmpty) batteryPercent = v.first;
          }
        }
      }

      // Fall back to structure when the UUIDs are not the expected ones —
      // the command channel is always one writable char plus one notify char.
      if (_write == null || _notify == null) {
        _log('expected fff6/fff7 not found — matching by properties instead');
        for (final s in services) {
          for (final c in s.characteristics) {
            if (_write == null &&
                (c.properties.write || c.properties.writeWithoutResponse)) {
              _write = c;
            }
            if (_notify == null && c.properties.notify) _notify = c;
          }
        }
      }

      if (_write == null || _notify == null) {
        _log('no usable command channel — cannot talk to this device');
        await target.disconnect();
        state = LinkState.idle;
        _emit();
        return false;
      }

      await _notify!.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = _notify!.lastValueStream.listen(_onNotify);

      device = target;
      deviceName = target.platformName;
      await Profile.instance.rememberBand(target.remoteId.str, model,
          displayName: target.platformName);
      state = LinkState.connected;
      _log('connected — write ${_write!.uuid.str}, notify ${_notify!.uuid.str}');
      if (firmware != null) {
        _log('firmware $firmware  hardware $hardware');
      } else {
        // No Device Information Service on this family, so the standard
        // firmware-revision characteristic is not there. Ask the protocol.
        unawaited(readVersion());
      }
      _emit();
      return true;
    } catch (e) {
      _log('connect failed: $e');
      state = LinkState.idle;
      _emit();
      return false;
    }
  }

  Future<String?> _readString(BluetoothCharacteristic c) async {
    if (!c.properties.read) return null;
    try {
      final v = await c.read();
      return String.fromCharCodes(v).trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnect() async {
    // The user's explicit stop. This is the ONLY thing that ends the
    // reconnect loop — every other path treats a dropped link as temporary.
    _userDisconnected = true;
    _cancelReconnect();
    _reconnectTarget = null;
    await _notifySub?.cancel();
    await _connSub?.cancel();
    try {
      await device?.disconnect();
    } catch (_) {}
    state = LinkState.idle;
    _write = null;
    _notify = null;
    _forgetIdentity();
    // The candidate list was captured before this connection began, so by now
    // it is at least one session out of date. Returning to an empty Scan
    // button is honest; re-offering those rows invites a tap on a band that
    // may no longer be there.
    found.clear();
    _emit();
  }

  /// Schedule the next reconnect attempt.
  ///
  /// Backoff is capped at 30 s and never gives up: "as long as it is in
  /// range" has no deadline, and a band that is out of range simply fails
  /// each attempt cheaply until it is back. The cost of retrying forever is
  /// one connect attempt every 30 s; the cost of giving up is silently
  /// missing every sample from here on.
  void _scheduleReconnect() {
    if (_userDisconnected || _reconnectTarget == null) return;

    // First caller wins. A FAILED attempt notifies twice — the connectionState
    // listener sees `disconnected` and _tryReconnect sees `ok == false` — and
    // both used to schedule, so the attempt counter advanced twice per failure
    // and the backoff reached its 30 s cap in half the tries. Observed live:
    // "in 4s (attempt 2)" and "in 8s (attempt 3)" logged in the same
    // millisecond.
    if (_reconnectTimer?.isActive ?? false) return;

    const steps = [2, 4, 8, 15, 30];
    final secs = steps[_reconnectAttempt.clamp(0, steps.length - 1)];
    _reconnectAttempt++;
    reconnecting = true;
    _log('reconnecting to $_reconnectName in ${secs}s '
        '(attempt $_reconnectAttempt)');
    _emit();

    _reconnectTimer = Timer(Duration(seconds: secs), _tryReconnect);
  }

  Future<void> _tryReconnect() async {
    final target = _reconnectTarget;
    if (_userDisconnected || target == null) {
      reconnecting = false;
      _emit();
      return;
    }
    // Someone connected by hand while we were waiting. Stand down rather
    // than tearing down their link.
    if (state == LinkState.connected || state == LinkState.connecting) {
      reconnecting = false;
      _emit();
      return;
    }

    final ok = await connect(target);
    if (_userDisconnected) return;
    if (ok) {
      _reconnectAttempt = 0;
      reconnecting = false;
      _log('reconnected');
      _emit();
      try {
        await onReconnected?.call();
      } catch (e) {
        _log('post-reconnect sync failed: $e');
      }
      return;
    }
    _scheduleReconnect();
  }

  /// Give up on reconnecting — the user asked to stop.
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    reconnecting = false;
  }

  /// Reconnect to the band from the last session, if it is in range.
  ///
  /// Called once at startup. The remembered id is the BLE ADDRESS, not the
  /// advertised name — the name is mutable (this band renamed itself from
  /// "JCV8B 44300D" to "V5" mid-session) and a name-based match would have
  /// silently stopped recognising it.
  ///
  /// Why it scans rather than connecting straight to the address: a direct
  /// connect to a band that is not there blocks for the full 25 s connect
  /// timeout, so an app started away from the band would sit on "Connecting…"
  /// for half a minute at every launch. Scanning answers "is it here?" in a
  /// second or two and costs nothing when the answer is no.
  ///
  /// Never throws, and returns false rather than reporting a problem: no band
  /// in range at startup is the ordinary case, not an error.
  Future<bool> connectToRemembered({
    Duration lookFor = const Duration(seconds: 8),
  }) async {
    try {
      if (connected ||
          state == LinkState.connecting ||
          state == LinkState.scanning) {
        return false;
      }
      final id = Profile.instance.bandId;
      if (id == null || id.isEmpty) return false;

      if (!await FlutterBluePlus.isSupported) return false;
      if (await preflight(requesting: false) != BleBlocker.none) {
        _log('last band: Bluetooth is off');
        return false;
      }

      _log('looking for last band $id');
      // scan() publishes into `found` as devices are heard, so this can stop
      // the moment the right one appears instead of waiting out the window.
      unawaited(scan(timeout: lookFor));

      final deadline = DateTime.now().add(lookFor + const Duration(seconds: 2));
      Candidate? hit;
      while (DateTime.now().isBefore(deadline) && hit == null) {
        await Future.delayed(const Duration(milliseconds: 250));
        for (final c in found) {
          if (c.device.remoteId.str == id) {
            hit = c;
            break;
          }
        }
      }

      if (hit == null) {
        _log('last band not in range');
        await stopScan();
        return false;
      }

      // Android refuses to connect while a scan is running.
      await stopScan();
      _log('found last band, reconnecting');
      final ok = await connect(hit.device);
      if (!ok) return false;

      await identifyModel();
      await readBattery();
      return true;
    } catch (e) {
      _log('auto-connect failed: $e');
      return false;
    }
  }

  void _onNotify(List<int> data) {
    if (data.isEmpty) return;
    final r = Reply(Uint8List.fromList(data), DateTime.now());
    replies.add(r);
    if (replies.length > 4000) replies.removeRange(0, replies.length - 4000);
    _replyStream.add(r);
  }

  // ---------------------------------------------------------------- send

  bool _withoutResponse = true;

  /// Write one frame. Returns everything that arrived within [wait].
  Future<List<Reply>> send(Uint8List f,
      {Duration wait = const Duration(milliseconds: 1200)}) async {
    final c = _write;
    if (c == null) throw StateError('not connected');
    final mark = replies.length;
    try {
      await c.write(f, withoutResponse: _withoutResponse);
    } catch (e) {
      // Some firmware accepts only one of the two write modes.
      _withoutResponse = !_withoutResponse;
      try {
        await c.write(f, withoutResponse: _withoutResponse);
        _log('switched to write-'
            '${_withoutResponse ? "without" : "with"}-response');
      } catch (e2) {
        _log('write failed: $e2');
        return const [];
      }
    }
    await Future.delayed(wait);
    return replies.sublist(mark);
  }

  Future<List<Reply>> sendOp(int opcode,
      {List<int> payload = const [],
      Duration wait = const Duration(milliseconds: 1200)}) {
    return send(j.frame(opcode, payload: payload, checksum: checksum),
        wait: wait);
  }

  /// Run a full history transfer, including the mandatory resume.
  ///
  /// Two things make this more than "send and collect":
  ///
  /// The firmware pauses after 50 frames and waits for the same command with
  /// mode `0x02`. Without that resume a multi-day sync stalls partway through
  /// and looks exactly like a dropped connection.
  ///
  /// And there is no length header. The last frame ends with `0xFF`, but a
  /// real HR sample of 255 or a temperature high byte can produce that too,
  /// so an idle window is the backstop — plus a repeated record index, since
  /// the firmware will loop a page rather than signal the end.
  Future<List<Uint8List>> pullHistory(
    int opcode, {
    int mode = j.syncAll,
    DateTime? cursor,
    Duration idle = const Duration(seconds: 4),
    Duration limit = const Duration(seconds: 120),
    bool retryOnGap = true,
  }) async {
    if (!connected) return const [];
    final mark = replies.length;
    final started = DateTime.now();

    await send(
        j.historyFrame(opcode,
            mode: mode, cursor: cursor, checksum: checksum),
        wait: const Duration(milliseconds: 600));

    var batchStart = mark;
    var lastCount = replies.length;
    var lastChange = DateTime.now();

    while (DateTime.now().difference(started) < limit) {
      await Future.delayed(const Duration(milliseconds: 250));
      final now = replies.length;

      if (now != lastCount) {
        lastCount = now;
        lastChange = DateTime.now();

        if (j.isStreamEnd(replies.last.data)) break;

        if (now - batchStart >= j.streamBatchLimit) {
          batchStart = now;
          _log('resuming after ${j.streamBatchLimit} frames');
          await send(
              j.historyFrame(opcode,
                  mode: j.syncContinue, checksum: checksum),
              wait: const Duration(milliseconds: 400));
        }
        continue;
      }

      if (DateTime.now().difference(lastChange) > idle) break;
    }

    final buf = BytesBuilder();
    for (final r in replies.sublist(mark)) {
      buf.add(r.data);
    }
    final res = j.splitRecords(buf.toBytes(), opcode);

    final seen = <int>{};
    final out = <Uint8List>[];
    for (final r in res.records) {
      final idx = j.recordIndex(r);
      if (idx != null && !seen.add(idx)) {
        _log('record index $idx repeated — stopping');
        break;
      }
      out.add(r);
    }

    _log('${j.opName(opcode)}: ${out.length} record(s)'
        '${res.leftover.isNotEmpty ? ", ${res.leftover.length}B unparsed" : ""}');

    // Record indices are consecutive. A hole means a notification was lost or
    // a record was corrupted badly enough that the resyncing splitter skipped
    // it — which really happens: one sleep sync arrived as indices 4,3,2,0 and
    // the missing segment silently shortened the night by two hours.
    final missing = _missingIndices(out, opcode);
    if (missing.isNotEmpty && retryOnGap) {
      _log('${j.opName(opcode)}: missing index/indices '
          '${_asRanges(missing)} — re-pulling');
      final again = await pullHistory(opcode,
          mode: mode, cursor: cursor, idle: idle, limit: limit,
          retryOnGap: false);
      if (again.isNotEmpty) {
        final byIndex = <int, Uint8List>{};
        for (final r in [...again, ...out]) {
          final i = j.recordIndex(r);
          if (i != null) byIndex[i] = r;
        }
        final merged = byIndex.keys.toList()..sort();
        final result = [for (final i in merged) byIndex[i]!];
        final stillMissing = _missingIndices(result, opcode);
        _log('${j.opName(opcode)}: ${result.length} record(s) after merge'
            '${stillMissing.isEmpty ? "" : ", still missing "
                "${_asRanges(stillMissing)}"}');
        return result;
      }
    }
    return out;
  }

  /// Indices absent from an otherwise consecutive run.
  /// Indices missing from a record run, or empty when the question does not
  /// apply.
  ///
  /// [opcode] matters: not every record layout carries a sequence number at
  /// [1:3]. 0x51 daily totals put a BCD date there, so reading it as an index
  /// produced large unrelated numbers, and every sync invented a hole and
  /// burned a round trip re-pulling it. Observed live:
  /// "daily_totals: missing index/indices [9729]".
  ///
  /// A numeric heuristic does not save you here — those two pseudo-indices
  /// were ADJACENT, so any span test passes them. The only sound rule is
  /// whether the layout has an index at all.
  /// The widest run of absent indices still treated as lost records.
  ///
  /// Indices are 16-bit (`rec[1] | rec[2] << 8`), so one corrupted record
  /// reads as index 40,000 in a pull of nine — and every number in between
  /// then counted as missing. That produced a re-pull that could not possibly
  /// help, and an activity-log line tens of thousands of integers long, which
  /// pushed every real line off the card.
  static const _maxGapSpan = 512;

  @visibleForTesting
  List<int> missingIndicesForTest(List<Uint8List> records, int opcode) =>
      _missingIndices(records, opcode);

  @visibleForTesting
  static String rangesForTest(List<int> xs) => _asRanges(xs);

  List<int> _missingIndices(List<Uint8List> records, int opcode) {
    if (!j.recordHasIndex(opcode)) return const [];
    final idx = records
        .map(j.recordIndex)
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    if (idx.length < 2) return const [];
    final out = <int>[];
    for (var k = 1; k < idx.length; k++) {
      final gap = idx[k] - idx[k - 1] - 1;
      if (gap <= 0) continue;
      // Not a hole in a sequence — a number that was never part of one.
      if (gap > _maxGapSpan) continue;
      for (var i = idx[k - 1] + 1; i < idx[k]; i++) {
        out.add(i);
      }
    }
    return out;
  }

  /// Indices as runs: `12-19, 44, 51-53`, truncated after a few.
  ///
  /// The log is read on a phone, one line per entry. A bare `List<int>` of a
  /// hundred consecutive numbers says exactly what `3-102` says, at a
  /// hundredth of the width.
  static String _asRanges(List<int> xs, {int maxRuns = 6}) {
    if (xs.isEmpty) return '';
    final runs = <String>[];
    var from = xs.first, prev = xs.first;
    void close() =>
        runs.add(from == prev ? '$from' : '$from-$prev');
    for (final x in xs.skip(1)) {
      if (x == prev + 1) {
        prev = x;
        continue;
      }
      close();
      from = prev = x;
    }
    close();
    if (runs.length <= maxRuns) return runs.join(', ');
    return '${runs.take(maxRuns).join(', ')} '
        '(+${runs.length - maxRuns} more, ${xs.length} total)';
  }

  /// Ask the band what it actually is.
  ///
  /// A band advertising "J2501 B920" answers "J2208   B920": 2501 is a
  /// marketing SKU and 2208 is the protocol family. One round trip decides
  /// which opcode map applies.
  Future<String?> identifyModel() async {
    if (!connected) return null;
    final got = await sendOp(j.opGetName,
        wait: const Duration(milliseconds: 1500));
    for (final r in got) {
      // The name starts at [1]; byte 0 is the echoed opcode (0x3E renders as
      // '>') and the frame ends with a checksum byte, so filtering printable
      // characters across the whole frame produced ">44300D}".
      if (r.data.length < 2 || r.opcode != j.opGetName) continue;
      final body = r.data.skip(1).takeWhile((b) => b != 0);
      final text =
          String.fromCharCodes(body.where((b) => b >= 32 && b < 127)).trim();
      if (text.isNotEmpty) {
        model = text;
        _log('model reports: "$text"');
        _emit();
        return text;
      }
    }
    _log('no model name returned');
    return null;
  }

  /// Read the battery level via opcode 0x13.
  ///
  /// This band exposes no standard Battery Service, so the only route is the
  /// protocol itself: reply `[1]` is the percentage. Confirmed reading 100 on
  /// a full band.
  /// Forget everything identifying the PREVIOUS band.
  ///
  /// These fields are not cleared by disconnecting, so connecting to a second
  /// band used to inherit the first one's identity. Worse than a stale label:
  /// `connect` only asks for a firmware version when `firmware == null`, so
  /// the carried-over value also SUPPRESSED the read that would have
  /// corrected it. Observed live — a V5 reported the 2208A's 0.0.3.8.
  @visibleForTesting
  void forgetIdentityForTest() => _forgetIdentity();

  void _forgetIdentity() {
    firmware = null;
    hardware = null;
    model = null;
    manufacturer = null;
    serial = null;
  }

  /// Drop the previous scan's results.
  ///
  /// A candidate list is a snapshot of what was advertising during one scan,
  /// not an inventory of nearby bands. Showing it again on a later visit
  /// invites a tap on a band that has since gone away or moved out of range —
  /// and the failure is not a harmless "nothing happened": the rows are
  /// ordered by score then signal, so a stale list can put a DIFFERENT band
  /// under the same thumb position. That has already happened once here, when
  /// a tap aimed at the V5 connected to the 2208A.
  ///
  /// Never clears mid-scan. Doing so would delete results as they arrive,
  /// which is the exact opposite of showing them the moment they are found.
  void clearFound() {
    if (state == LinkState.scanning || found.isEmpty) return;
    found.clear();
    _emit();
  }

  /// Stop an in-progress scan early.
  ///
  /// Needed because the candidate list is live: a user who taps a band two
  /// seconds in should not wait out the remaining eighteen, and Android
  /// refuses to connect while a scan is running.
  Future<void> stopScan() async {
    if (state != LinkState.scanning) return;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Already stopped, or the adapter went away — either way there is
      // nothing to stop and the connect attempt should still proceed.
    }
    state = LinkState.idle;
    _log('scan stopped early');
    _emit();
  }

  /// Ask the band its firmware version (0x27).
  ///
  /// Used when there is no Device Information Service to read it from, which
  /// is the case on the 2208A. Safe: a read.
  Future<String?> readVersion() async {
    final replies = await send(
        j.frame(j.opGetVersion, checksum: checksum),
        wait: const Duration(milliseconds: 1200));
    for (final r in replies) {
      final v = j.parseVersion(r.data);
      if (v != null) {
        firmware = v;
        _log('firmware $v (from 0x27)');
        _emit();
        return v;
      }
    }
    _log('no firmware version returned');
    return null;
  }

  /// Read the background-monitoring schedule for one sensor (0x2B).
  ///
  /// Safe: a read. Worth doing before any write, because it turns out the
  /// setting is often already on — this band had heart-rate sampling enabled
  /// all along, and the empty history was the app reading the wrong opcode.
  Future<j.AutoMonitor?> readAutoMonitor(int sensor) async {
    // Two attempts, and a wait with real headroom.
    //
    // This started at a single 1200 ms try, and it silently produced a WRONG
    // ANSWER rather than an obvious failure: sensor 4 timed out, the method
    // returned null, and null renders as "no reply (likely unsupported)". On
    // that basis HRV was recorded as unsupported on the V5 and Recovery
    // declared permanently unfillable. A raw probe later showed sensor 4
    // answering perfectly well — mode 2, every 60 minutes.
    //
    // A timeout and a refusal are not the same thing, and this method must
    // not let the caller confuse them.
    for (var attempt = 0; attempt < 2; attempt++) {
      final replies = await send(
          j.frame(j.opGetAutoMonitor, payload: [sensor], checksum: checksum),
          wait: const Duration(milliseconds: 2500));
      for (final r in replies) {
        final m = j.parseAutoMonitor(r.data);
        // Match the sensor we asked about: a late reply for another sensor
        // must not be mistaken for this one's setting.
        if (m != null && m.sensor == sensor) return m;
      }
    }
    _log('sensor $sensor: no answer after 2 tries — UNKNOWN, not "off"');
    return null;
  }

  /// Write the background-monitoring schedule for one sensor (0x2A).
  ///
  /// ⚠ This is a WRITE, and it is the opcode that decides whether the band
  /// records anything optically at all. Two public implementations disagree
  /// about 0x2A's meaning, so this sends the SDK's documented layout and then
  /// reads it back with 0x2B to confirm the band understood it the same way.
  /// A write that cannot be verified is not reported as success.
  Future<j.AutoMonitor?> writeAutoMonitor(j.AutoMonitor m) async {
    _log('setting sensor ${m.sensor} monitoring: '
        '${m.enabled ? "on" : "off"}, ${m.window}, every '
        '${m.intervalMinutes} min');
    await send(j.frame(j.opSetAutoMonitor,
        payload: m.toPayload(), checksum: checksum));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final back = await readAutoMonitor(m.sensor);
    if (back == null) {
      _log('  wrote it, but the band did not read back — unverified');
    } else {
      _log('  band now reports: ${back.enabled ? "on" : "off"}, '
          '${back.window}, every ${back.intervalMinutes} min');
    }
    return back;
  }

  Future<int?> readBattery() async {
    if (!connected) return null;
    final got = await sendOp(j.opBattery,
        wait: const Duration(milliseconds: 1200));
    for (final r in got) {
      if (r.opcode == j.opBattery && r.data.length > 1) {
        final v = r.data[1];
        if (v >= 0 && v <= 100) {
          batteryPercent = v;
          _log('battery $v%');
          _emit();
          return v;
        }
      }
    }
    return null;
  }

  /// Today's step/calorie/distance counters via opcode 0x26.
  ///
  /// The field layout is not yet pinned down, so this returns the raw reply
  /// for the caller to interpret rather than inventing an offset.
  Future<List<int>?> readStepsRaw() async {
    if (!connected) return null;
    final got = await sendOp(j.opStepsToday,
        wait: const Duration(milliseconds: 1200));
    for (final r in got) {
      if (r.opcode == j.opStepsToday) return r.data.toList();
    }
    return null;
  }

  /// Pull per-day activity totals (steps, distance, calories, active time).
  Future<List<j.DailyTotals>> readDailyTotals() async {
    if (!connected) return const [];
    final recs = await pullHistory(j.opDailyTotals);
    final out = recs
        .map(j.parseDailyTotals)
        .whereType<j.DailyTotals>()
        .toList();
    if (out.isNotEmpty) {
      _log('activity: ${out.length} day(s), latest ${out.last.steps} steps');
    }
    return out;
  }

  /// Measure skin temperature.
  ///
  /// Temperature is NOT in any history opcode — `0x3B` always answers
  /// "nothing stored". It exists only in the 0x09 realtime frame, and that
  /// frame is all zeros unless a measurement is running. So the sequence is
  /// 0x28 start -> poll 0x09 -> 0x28 stop.
  ///
  /// Confirmed on hardware: read 33.4 C and 32.4 C on two measurements.
  Future<double?> measureTemperature({
    Duration limit = const Duration(seconds: 60),
  }) async {
    if (!connected) return null;
    _log('measuring temperature — keep the band on, still');
    await sendOp(j.opMeasure,
        payload: j.measurePayload(on: true),
        wait: const Duration(milliseconds: 900));

    double? found;
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline) && found == null) {
      final got = await sendOp(j.opRealtime,
          wait: const Duration(milliseconds: 1200));
      for (final r in got) {
        final c = j.parseRealtimeTemperature(r.data);
        if (c != null) {
          found = c;
          break;
        }
      }
      if (found == null) await Future.delayed(const Duration(seconds: 1));
    }

    await sendOp(j.opMeasure, payload: j.measurePayload(on: false));
    if (found != null) {
      _log('temperature ${found.toStringAsFixed(1)} C');
    } else {
      _log('temperature did not converge — is the band being worn?');
    }
    _emit();
    return found;
  }

  /// Find which checksum the firmware accepts, using reads only.
  ///
  /// Returns the variant that produced replies, or null if none did.
  Future<String?> detectChecksum() async {
    if (!connected) return null;
    _log('detecting checksum...');
    final scores = <String, int>{};
    for (final probe in [j.opBattery, j.opDeviceInfo]) {
      for (final name in j.checksums.keys) {
        final got = await send(j.frame(probe, checksum: name),
            wait: const Duration(milliseconds: 900));
        if (got.isNotEmpty) scores[name] = (scores[name] ?? 0) + got.length;
      }
    }
    if (scores.isEmpty) {
      _log('no checksum variant got a reply');
      return null;
    }
    final best =
        scores.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    checksum = best;
    _log('checksum = $best  (scores: $scores)');
    _emit();
    return best;
  }
}
