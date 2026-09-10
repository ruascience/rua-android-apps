import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ble/band_link.dart';
import '../data/profile.dart';
import '../data/cloud_sync.dart';
import '../data/store.dart';
import '../data/sync_service.dart';
import '../protocol/jstyle.dart' as j;
import 'kit.dart';
import 'lab_page.dart';
import 'profile_edit.dart';

/// Device management — the clone of the vendor's "My Device" screen, plus the
/// sync controls and the profile the derived metrics need.
class DevicePage extends StatefulWidget {
  const DevicePage({super.key});
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final link = BandLink.instance;
  final Map<int, j.AutoMonitor?> _monitors = {};
  bool _monitorBusy = false;
  final profile = Profile.instance;
  final sampler = PeriodicSampler.instance;
  final cloud = CloudSync.instance;

  /// Hides "Background monitoring" and "Lab and findings".
  ///
  /// A field rather than a deletion so restoring them is one word, and a
  /// field rather than a `const` so the builders stay referenced and the
  /// analyzer does not report them as unused.
  ///
  /// ⚠ One thing still goes with them and has no other route in the app:
  /// the findings corpus and opcode explorer (Lab was already off the bottom
  /// bar). Editing the profile no longer does — "Your details" below is a
  /// deliberate route to it, outside this flag, because the first-run sheet
  /// being the only place those are ever entered made a typo permanent.
  final bool showAdvancedCards = false;
  late final TextEditingController _urlCtl =
      TextEditingController(text: cloud.baseUrl);
  late final TextEditingController _userCtl =
      TextEditingController(text: cloud.authUser);
  late final TextEditingController _passCtl =
      TextEditingController(text: cloud.authPass);
  bool _showPass = false;

  /// Live scan results. BandLink publishes each device as it is heard, and
  /// this page rebuilds on link.changes, so the list fills in as the scan
  /// runs instead of appearing all at once when it times out.
  List<Candidate> get found => link.found;
  bool busy = false;
  String busyLabel = '';
  Map<String, int> counts = const {};

  @override
  void initState() {
    super.initState();
    profile.load().then((_) => mounted ? setState(() {}) : null);
    // Evaluate the blocker without prompting: the card should already be
    // showing when the user arrives, not only after a scan has failed once.
    link.preflight(requesting: false).then((_) {
      if (mounted) setState(() {});
    });
    _refreshCounts();
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  Future<void> _run(String label, Future<void> Function() body) async {
    setState(() {
      busy = true;
      busyLabel = label;
    });
    try {
      await body();
    } catch (e) {
      // The log keeps the detail; the user gets told. Appending only to the
      // activity log meant a failed action and a successful one looked
      // identical — the button simply came back.
      link.log.add('error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${label.toLowerCase()} failed — ${_short('$e')}'),
          action: SnackBarAction(
              label: 'Details',
              onPressed: () => Scrollable.ensureVisible(context)),
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          busyLabel = '';
        });
      }
    }
  }

  /// Snackbars are one line on a phone; a Dart exception is often three.
  static String _short(String e) =>
      e.length <= 90 ? e : '${e.substring(0, 90)}…';

  /// Persist whatever is in the credential fields.
  ///
  /// Called from both the Test button and either field's submit, so a user
  /// who types a token and taps Test does not silently test the old one.
  Future<void> _saveAuth() async {
    await cloud.setAuth(_userCtl.text, _passCtl.text);
    if (mounted) setState(() {});
  }

  Future<void> _refreshCounts() async {
    if (link.deviceName.isEmpty) return;
    final c = Map<String, int>.from(
        await Store.instance.counts(link.deviceName));
    // Sleep lives in its own table, so it would otherwise be invisible here —
    // which is exactly the state that hid a sync bug.
    final segs = await Store.instance.readSleepSegments(link.deviceName);
    if (segs.isNotEmpty) c['sleep segments'] = segs.length;
    if (mounted) setState(() => counts = c);
  }

  Future<void> _scan() => _run('Scanning for bands', () async {
        // The result is ignored on purpose: link.found is already being
        // populated as devices are heard, and this page reads it live.
        await link.scan(timeout: const Duration(seconds: 20));
      });

  Future<void> _connect(Candidate c) => _run('Connecting', () async {
        // Android will not connect while a scan is running, and the scan
        // task is still awaiting its timeout at this point.
        await link.stopScan();
        if (await link.connect(c.device)) {
          await link.identifyModel();
          await link.readBattery();
          await _refreshCounts();
        }
      });

  /// Pull every history type the band answers and store what parses.
  ///
  /// The work itself lives in SyncService because reconnection needs it too,
  /// with no UI attached.
  Future<void> _sync() async {
    // The startup auto-connect starts a sync of its own, and syncAll() guards
    // against two at once. Without this the tap looked like a dead button for
    // the whole first minute after launch.
    if (SyncService.instance.busy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Already syncing — this one is still running')));
      }
      return;
    }
    await _run('Syncing history', () async {
      await SyncService.instance.syncAll();
      await _refreshCounts();
    });
  }

  Future<void> _measure() => _run('Measuring — keep still', () async {
        final start = link.replies.length;
        await link.sendOp(j.opMeasure,
            payload: j.measurePayload(on: true),
            wait: const Duration(milliseconds: 600));

        // The band acks immediately with an all-zero frame and only sends
        // real values ~30 s later. Taking the ack for the answer cancels the
        // measurement every time, so wait for a frame that actually parses.
        j.LiveReading? got;
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(deadline) && got == null) {
          await Future.delayed(const Duration(milliseconds: 500));
          for (final r in link.replies.skip(start)) {
            if (r.opcode != j.opMeasure) continue;
            final p = j.parseOnDemand(r.data);
            if (p != null && p.hasAnything) {
              got = p;
              break;
            }
          }
        }
        // Temperature only exists in the realtime frame, so grab it while
        // the sensor is still running rather than in a second pass.
        double? tempC;
        for (final r in link.replies.skip(start)) {
          final c = j.parseRealtimeTemperature(r.data);
          if (c != null) tempC = c;
        }
        tempC ??= await link.measureTemperature(
            limit: const Duration(seconds: 30));

        await link.sendOp(j.opMeasure, payload: j.measurePayload(on: false));

        if (tempC != null) {
          await Store.instance.putSamples(
              link.deviceName, 'temperature', [Sample(DateTime.now(), tempC)]);
        }

        if (got == null && tempC == null) {
          link.log.add('no reading — sensor did not converge');
          return;
        }
        final now = DateTime.now();
        final dev = link.deviceName;
        Future<void> put(String m, num v) =>
            Store.instance.putSamples(dev, m, [Sample(now, v.toDouble())]);
        if (got != null) {
          if (got.heartRate > 0) await put('heart_rate', got.heartRate);
          if (got.spo2 > 0) await put('spo2', got.spo2);
          if (got.hrvMs > 0) await put('hrv', got.hrvMs);
        }
        await _refreshCounts();
        if (mounted) {
          final bits = <String>[
            if (got != null && got.heartRate > 0) 'HR ${got.heartRate}',
            if (got != null && got.spo2 > 0) 'SpO₂ ${got.spo2}%',
            if (got != null && got.hrvMs > 0) 'HRV ${got.hrvMs} ms',
            if (tempC != null) '${tempC.toStringAsFixed(1)} °C',
          ];
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(bits.join(' · '))));
        }
      });

  Future<void> _loadMonitors() async {
    if (!link.connected || _monitorBusy) return;
    setState(() => _monitorBusy = true);
    for (final sensor in const [
      j.autoSensorHeartRate,
      j.autoSensorSpo2,
      j.autoSensorTemperature,
      j.autoSensorHrv,
    ]) {
      _monitors[sensor] = await link.readAutoMonitor(sensor);
    }
    if (mounted) setState(() => _monitorBusy = false);
  }

  Future<void> _setMonitor(int sensor, bool on, int minutes) async {
    setState(() => _monitorBusy = true);
    final back = await link.writeAutoMonitor(on
        ? j.AutoMonitor.allDay(sensor, minutes)
        : j.AutoMonitor(
            enabled: false,
            startHour: 0,
            startMinute: 0,
            endHour: 23,
            endMinute: 59,
            weekdayMask: 0xFF,
            intervalMinutes: minutes,
            sensor: sensor));
    _monitors[sensor] = back;
    if (mounted) setState(() => _monitorBusy = false);
  }

  static const _sensorNames = {
    j.autoSensorHeartRate: 'Heart rate',
    j.autoSensorSpo2: 'Blood oxygen',
    j.autoSensorTemperature: 'Skin temperature',
    j.autoSensorHrv: 'HRV',
  };

  /// App-driven sampling on a fixed interval.
  ///
  /// Sits next to the Background monitoring card on purpose: at the current
  /// 5-minute interval the two do the same job, and the band's own scheduler
  /// does it more cheaply. The copy says so rather than letting someone burn
  /// band battery to duplicate what 0x2A already gives them.
  Widget _toolsCard(ThemeData t) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Continuous sampling', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Asks the band for heart rate, HRV, blood oxygen and skin '
              'temperature every 5 minutes while it is connected.\n\n'
              'Background monitoring above does the same job more cheaply at '
              'this interval: the band logs on its own, with the phone out of '
              'range, and you read it back on the next sync. This one only '
              'runs while connected and lights the sensor for ~30 seconds a '
              'time. Use it when you want the reading now rather than at the '
              'next sync.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: sampler.enabled,
              title: Text('Sample every '
                  '${PeriodicSampler.period.inMinutes} minutes'),
              subtitle: Text(
                  sampler.lastSampleAt == null
                      ? 'no sample yet'
                      : 'last: ${sampler.lastResult}',
                  style: TextStyle(color: kMuted, fontSize: 11)),
              onChanged: (v) => setState(
                  () => v ? sampler.start() : sampler.stop()),
            ),
          ]),
        ),
      );

  /// Cloud sync status.
  ///
  /// Shown with a PENDING COUNT rather than a tick, because "synced" is not a
  /// state this can honestly claim: the phone is the system of record and the
  /// server is allowed to be behind. What matters is whether the backlog is
  /// shrinking, and whether the last attempt failed and why.
  Widget _cloudCard(ThemeData t) => StreamBuilder<void>(
        stream: cloud.changes,
        builder: (context, _) {
          final (IconData icon, String label, Color colour) =
              switch (cloud.state) {
            CloudState.syncing => (Icons.cloud_sync, 'Syncing…', kAccent),
            CloudState.idle when cloud.pending == 0 => (
                Icons.cloud_done,
                'Up to date',
                kAccent
              ),
            CloudState.idle => (Icons.cloud_queue, 'Queued', kMuted),
            CloudState.offline => (
                Icons.cloud_off,
                'Server unreachable — queued',
                kMuted
              ),
            CloudState.error => (Icons.error_outline, 'Sync error', kBad),
          };

          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon, size: 18, color: colour),
                      const SizedBox(width: 8),
                      Text('Cloud sync', style: t.textTheme.titleMedium),
                      const Spacer(),
                      Text(label,
                          style: t.textTheme.labelMedium
                              ?.copyWith(color: colour)),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      'Every row written on this phone is pushed to the API '
                      'and stored in MongoDB. Nothing is lost while the '
                      'server is down — rows stay queued and go up on the '
                      'next attempt.',
                      style: t.textTheme.bodySmall?.copyWith(color: kMuted),
                    ),
                    const SizedBox(height: 12),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          BigStat('${cloud.pending}', '', 'waiting',
                              color: cloud.pending == 0 ? kAccent : kMuted),
                          BigStat('${cloud.pushedThisSession}', '',
                              'sent this session'),
                          BigStat(
                              cloud.lastSuccess == null
                                  ? '—'
                                  : DateFormat.Hm().format(cloud.lastSuccess!),
                              '',
                              'last sent'),
                        ]),
                    if (cloud.lastError.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(cloud.lastError,
                          style: t.textTheme.bodySmall?.copyWith(color: kBad)),
                    ],
                    const Divider(height: 24),
                    TextField(
                      controller: _urlCtl,
                      decoration: const InputDecoration(
                        labelText: 'API base URL',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (v) async {
                        await cloud.setBaseUrl(v);
                        if (mounted) setState(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    // The credential belongs beside the URL it authenticates
                    // to. Without these fields, pointing the app at another
                    // server left no way to authenticate to it: every sync
                    // answered 401 and the outbox simply paused.
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _userCtl,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _saveAuth(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _passCtl,
                          obscureText: !_showPass,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Token',
                            isDense: true,
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: _showPass ? 'Hide token' : 'Show token',
                              icon: Icon(
                                  _showPass
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  size: 18),
                              onPressed: () =>
                                  setState(() => _showPass = !_showPass),
                            ),
                          ),
                          onSubmitted: (_) => _saveAuth(),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await cloud.setBaseUrl(_urlCtl.text);
                          await _saveAuth();
                          final ok = await cloud.ping();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(ok
                                  ? 'Server reachable'
                                  : 'Not reachable: ${cloud.lastError}')));
                        },
                        icon: const Icon(Icons.network_check, size: 16),
                        label: const Text('Test'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => cloud.flush(),
                        icon: const Icon(Icons.cloud_upload, size: 16),
                        label: const Text('Sync now'),
                      ),
                      TextButton(
                        onPressed: () async {
                          // After pointing at a different server, that one
                          // holds none of this — so everything must go again.
                          await Store.instance.resetSyncState();
                          await cloud.refreshPending();
                          unawaited(cloud.flush());
                        },
                        child: const Text('Re-send all'),
                      ),
                    ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: cloud.enabled,
                      title: const Text('Sync to server'),
                      onChanged: (v) async {
                        await cloud.setEnabled(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ]),
            ),
          );
        },
      );

  /// Lab and findings, reachable whether or not a band is connected.
  ///
  /// Lab left the bottom bar as asked, but the findings corpus was reachable
  /// ONLY from there. Gating it behind a live connection would have hidden it
  /// exactly when it is most useful — you consult the findings to work out why
  /// the band will not connect.
  Widget _labCard(ThemeData t) => Card(
        child: ListTile(
          leading: Icon(Icons.science_outlined, color: kMuted),
          title: const Text('Lab and findings'),
          subtitle: Text(
              'Opcode explorer, and everything established about this protocol',
              style: TextStyle(color: kMuted, fontSize: 11)),
          trailing: const Icon(Icons.chevron_right),
          // Wrapped in a Scaffold at the call site: LabPage was written as a
          // tab body and takes its Material ancestor from the Shell. Pushed
          // as a route it has none, and its TextFields throw on build.
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Lab')),
              body: const LabPage(),
            ),
          )),
        ),
      );

  /// Background monitoring — the setting that decides whether the band
  /// records anything optically when you are not asking it to.
  Widget _monitorCard(ThemeData t) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Background monitoring', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'How often the band samples each sensor on its own. A sensor '
              'switched off here records nothing, and its history then reads '
              'empty — indistinguishable from a band that lacks the hardware.',
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_monitors.isEmpty)
              FilledButton.tonalIcon(
                onPressed:
                    (!link.connected || _monitorBusy) ? null : _loadMonitors,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Read current settings'),
              )
            else
              for (final e in _monitors.entries) ...[
                _monitorRow(t, e.key, e.value),
                const SizedBox(height: 8),
              ],
            if (_monitorBusy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
          ]),
        ),
      );

  Widget _monitorRow(ThemeData t, int sensor, j.AutoMonitor? m) {
    final name = _sensorNames[sensor] ?? 'sensor $sensor';
    if (m == null) {
      return Row(children: [
        const Icon(Icons.remove, size: 16, color: kMuted),
        const SizedBox(width: 8),
        Expanded(
            // NOT "unsupported": a silent sensor is an unknown, and reading
            // it as a fact about the hardware is exactly how HRV came to be
            // recorded as absent from this band when it was scheduled hourly.
            child: Text('$name — could not read (unknown)',
                style: t.textTheme.bodySmall?.copyWith(color: kMuted))),
      ]);
    }
    return Row(children: [
      Icon(m.enabled ? Icons.check_circle : Icons.cancel_outlined,
          size: 16,
          color: m.enabled ? t.colorScheme.primary : t.colorScheme.outline),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: t.textTheme.bodyMedium),
          Text(
              m.enabled
                  ? '${m.window}, every ${m.intervalMinutes} min'
                  : 'off',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
        ]),
      ),
      Switch(
        value: m.enabled,
        onChanged: _monitorBusy
            ? null
            : (v) => _setMonitor(sensor, v,
                m.intervalMinutes > 0 ? m.intervalMinutes : 5),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return StreamBuilder<void>(
      stream: link.changes,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text('My Device',
              style: t.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          if (busy) ...[
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 8),
            StreamBuilder<void>(
              stream: SyncService.instance.changes,
              builder: (context, _) {
                final svc = SyncService.instance;
                final detail = [
                  busyLabel,
                  if (svc.busy && svc.phase.isNotEmpty) svc.phase,
                  if (svc.storedThisRun > 0) '${svc.storedThisRun} stored',
                ].where((s) => s.isNotEmpty).join(' · ');
                return Text(detail,
                    style: t.textTheme.bodySmall?.copyWith(color: kMuted));
              },
            ),
            const SizedBox(height: 12),
          ],
          _detailsCard(t),
          const SizedBox(height: 12),
          if (link.connected) ..._connected(t) else ..._disconnected(t),
          if (showAdvancedCards) ...[
            const SizedBox(height: 12),
            _monitorCard(t),
          ],
          const SizedBox(height: 12),
          _logCard(t),
        ],
      ),
    );
  }

  /// Why a scan cannot find anything, and the one control that fixes it.
  ///
  /// Sits ABOVE the scan card, because when it is showing, tapping Scan is
  /// not the next thing to do — it is the thing that will keep appearing to
  /// do nothing.
  Widget? _blockerCard(ThemeData t) {
    final (String title, String body, String? action, VoidCallback? onTap) =
        switch (link.blocker) {
      BleBlocker.none => ('', '', null, null),
      BleBlocker.unsupported => (
          'This phone has no Bluetooth LE',
          'The band talks over Bluetooth Low Energy, and this device does not '
              'have it. Nothing here will find a band.',
          null,
          null,
        ),
      BleBlocker.adapterOff => (
          'Bluetooth is off',
          'The band is found over Bluetooth, so it has to be switched on '
              'before a scan can see anything.',
          'Turn on Bluetooth',
          () async {
            await link.requestAdapterOn();
            if (mounted) setState(() {});
          },
        ),
      BleBlocker.permissionDenied => (
          'Bluetooth permission not granted',
          'Android needs your permission before this app can look for nearby '
              'bands. Nothing is sent anywhere — the permission is only used '
              'to find and talk to your band.',
          'Ask again',
          () async {
            await link.preflight();
            if (mounted) setState(() {});
          },
        ),
      BleBlocker.permissionPermanentlyDenied => (
          'Bluetooth permission is blocked',
          'The permission was declined for good, so Android will not ask '
              'again from inside the app. It can still be granted from the '
              'app settings — Permissions, then Nearby devices.',
          'Open app settings',
          () => link.openPermissionSettings(),
        ),
    };
    if (title.isEmpty) return null;

    return Card(
      color: kBad.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.error_outline, size: 18, color: kBad),
            const SizedBox(width: 8),
            Expanded(
                child: Text(title,
                    style: t.textTheme.titleSmall?.copyWith(color: kBad))),
          ]),
          const SizedBox(height: 6),
          Text(body, style: t.textTheme.bodySmall),
          if (action != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: onTap, child: Text(action)),
            ),
          ],
        ]),
      ),
    );
  }

  List<Widget> _disconnected(ThemeData t) => [
        ?_blockerCard(t),
        if (link.blocker != BleBlocker.none) const SizedBox(height: 12),
        SectionCard(
          title: 'Not connected',
          subtitle: 'Your band holds one Bluetooth link at a time',
          child: Column(children: [
            const Icon(Icons.watch_off_outlined, size: 44, color: kMuted),
            const SizedBox(height: 14),
            Text(
              'If the band does not appear, close the vendor app — it keeps '
              'the connection open even after unpairing, which stops the band '
              'advertising to anyone else.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: kMuted),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : _scan,
                icon: const Icon(Icons.search),
                label: const Text('Scan for bands'),
              ),
            ),
          ]),
        ),
        if (found.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              // This row stays put when the scan ends — only its contents
              // change. Removing it would shift every band tile up by a row
              // exactly when results stop moving, and a tap already on its
              // way would land on the neighbour. That happened in testing:
              // a tap aimed at the V5 connected to the 2208A instead.
              ListTile(
                dense: true,
                leading: link.state == LinkState.scanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.check, size: 18, color: kMuted),
                title: Text(
                    link.state == LinkState.scanning
                        ? 'Still scanning — ${found.length} found'
                        : '${found.length} found',
                    style: TextStyle(color: kMuted)),
                subtitle: Text(
                    link.state == LinkState.scanning
                        ? 'Tap one as soon as you see it; the scan keeps '
                            'running for late-advertising bands.'
                        : 'Tap a band to connect.',
                    style: TextStyle(color: kMuted, fontSize: 11)),
              ),
              for (final c in found.take(12))
                ListTile(
                  leading: Icon(c.strong ? Icons.watch : Icons.bluetooth,
                      color: c.strong ? kAccent : kMuted),
                  title: Text(c.name.isEmpty ? '(unnamed)' : c.name),
                  subtitle: Text('signal ${c.rssi} dBm · match ${c.score}',
                      style: TextStyle(color: kMuted)),
                  trailing: const Icon(Icons.chevron_right),
                  // Enabled DURING a scan on purpose: showing a band early
                  // and then refusing the tap until the timeout expires
                  // would be the same wait with extra steps. Any other busy
                  // state (connecting, syncing) still blocks.
                  onTap: (busy && link.state != LinkState.scanning)
                      ? null
                      : () => _connect(c),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        _cloudCard(t),
        if (showAdvancedCards) ...[
          const SizedBox(height: 12),
          _labCard(t),
        ],
      ];

  List<Widget> _connected(ThemeData t) => [
        SectionCard(
          title: link.deviceName.isEmpty ? 'Band' : link.deviceName,
          subtitle: 'Connected',
          trailing: TextButton(
            onPressed: busy ? null : () => link.disconnect(),
            child: const Text('Disconnect'),
          ),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              BigStat(
                  link.batteryPercent?.toString() ?? '—', '%', 'battery',
                  color: (link.batteryPercent ?? 0) > 20 ? kAccent : kBad),
              BigStat(link.model ?? '—', '', 'model id'),
              BigStat(link.firmware ?? '—', '', 'firmware'),
            ]),
            const Divider(height: 28),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: busy ? null : _measure,
                icon: const Icon(Icons.favorite, size: 18),
                label: const Text('Measure now'),
              ),
              // Rebuilt on SyncService's own stream so an AUTOMATIC sync —
              // the one the startup reconnect fires — shows here too. A
              // button that is merely inert during it reads as broken.
              StreamBuilder<void>(
                stream: SyncService.instance.changes,
                builder: (context, _) {
                  final syncing = SyncService.instance.busy;
                  final svc = SyncService.instance;
                  return FilledButton.tonalIcon(
                    onPressed: (busy || syncing) ? null : _sync,
                    icon: syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync, size: 18),
                    // The phase, not just "Syncing…": this walks every history
                    // opcode the band answers and can take minutes, and a bare
                    // spinner cannot be told apart from a stuck one.
                    label: Text(syncing
                        ? (svc.phase.isEmpty ? 'Syncing…' : svc.phase)
                        : 'Sync history'),
                  );
                },
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => link.readBattery(),
                icon: const Icon(Icons.battery_std, size: 18),
                label: const Text('Battery'),
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        _toolsCard(t),
        const SizedBox(height: 12),
        _cloudCard(t),
        if (showAdvancedCards) ...[
          const SizedBox(height: 12),
          _labCard(t),
        ],
        if (counts.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Stored locally',
            subtitle: 'nothing leaves this phone',
            child: Column(
              children: counts.entries
                  .map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key.replaceAll('_', ' '),
                                style: TextStyle(color: kMuted)),
                            Text('${e.value}'),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ];

  /// The route to what the first-run sheet collected.
  ///
  /// It replaces an inline editor that was hidden behind [showAdvancedCards]
  /// and covered three of the six answers — no name, no sex, no period start
  /// — under its own bounds, which did not match the sheet's. Editing there
  /// also wrote on every keystroke and dropped the failure on the floor.
  ///
  /// Shown whether or not a band is connected — the numbers it holds are the
  /// ones every derived metric reads, and they have nothing to do with
  /// whether the band is in range — and ABOVE the band cards. Below them it
  /// landed under the cloud-sync card, a screen and a half down a lazily
  /// built list: reachable, but not by anyone who was not already looking
  /// for it, which is the state this replaces.
  ///
  /// Not titled "About you" — that is the first-run sheet's title, and the
  /// tabs sit in an IndexedStack which builds every page, so both strings
  /// would be in the tree at once and neither a person nor a test could tell
  /// which one they had found.
  Widget _detailsCard(ThemeData t) => Card(
        child: ListTile(
          leading: Icon(Icons.person_outline, color: kMuted),
          title: const Text('Your details'),
          subtitle: Text(_detailsSummary(),
              style: TextStyle(color: kMuted, fontSize: 11)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const ProfileEditPage()));
            if (!mounted) return;
            // The summary below reads the profile fields directly, so this
            // card has to be rebuilt here. Insights and Home get there on
            // their own, through Profile.changes.
            setState(() {});
            if (saved == true) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Saved')));
            }
          },
        ),
      );

  /// The stored answers, spelled out on the card itself.
  ///
  /// A typo is only worth fixing if you can see it, and age — the one that
  /// moves VO2max, strain and BioAge — appears nowhere else in the app.
  String _detailsSummary() => [
        if (profile.name.trim().isNotEmpty) profile.name.trim(),
        '${profile.age} yrs',
        switch (profile.sex) {
          Sex.female => 'female',
          Sex.male => 'male',
          Sex.unspecified => 'sex not set',
        },
        '${profile.heightCm} cm',
        '${formatWeightKg(profile.weightKg)} kg',
        // Shown only when set, the way the name above is. They are optional,
        // and "no email" printed on the card is a gap rather than an answer.
        //
        // Worth the extra line when they ARE set, for the same reason age is:
        // a mistyped address is invisible everywhere else in the app, and it
        // now rides along to the server on every profile push.
        if (profile.phoneNumber.trim().isNotEmpty) profile.phoneNumber.trim(),
        if (profile.email.trim().isNotEmpty) profile.email.trim(),
      ].join(' · ');

  Widget _logCard(ThemeData t) {
    final lines = link.log.reversed.take(30).toList();
    return SectionCard(
      title: 'Activity log',
      child: lines.isEmpty
          ? Text('nothing yet', style: TextStyle(color: kMuted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines
                  .map((l) => Text(l,
                      style: t.textTheme.labelSmall?.copyWith(
                          fontFamily: kMono, color: kMuted)))
                  .toList(),
            ),
    );
  }
}
