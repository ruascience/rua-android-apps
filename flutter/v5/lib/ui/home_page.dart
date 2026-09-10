import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../analytics/metrics.dart';
import '../ble/band_link.dart';
import '../protocol/findings.dart' as fd;
import '../data/profile.dart';
import '../data/store.dart';
import 'kit.dart';

/// Dashboard. Mirrors the vendor Home tab: activity rings, heart rate, blood
/// oxygen, sleep and a recovery read-out — all from our own band data.
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final link = BandLink.instance;

  List<Sample> hr = const [], spo2 = const [], hrv = const [], temp = const [];
  double steps = 0, kcal = 0, km = 0, activeMin = 0;
  Estimate? resting, recoveryScore, strainScore;
  bool loading = true;

  /// True when the 14-day window held more rows than the read returned.
  ///
  /// History has always checked this; Home did not, and Home is where the
  /// DERIVED numbers are — resting heart rate, recovery, strain. A silently
  /// clipped window there does not look wrong, it looks like a slightly
  /// different number, which is precisely the failure this project keeps
  /// coming back to: a plausible figure that is not a measurement.
  bool _clipped = false;

  /// Which device the currently displayed data was loaded for. The shell uses
  /// an IndexedStack, so these pages are built once at startup — before any
  /// band is connected — and would otherwise sit empty forever.
  String _loadedFor = '';
  int _loadedRevision = -1;
  StreamSubscription<void>? _linkSub;
  StreamSubscription<int>? _dataSub;
  StreamSubscription<void>? _profileSub;

  @override
  void initState() {
    super.initState();
    _load();
    _linkSub = link.changes.listen((_) {
      // Reload on disconnect as well: the page then falls back to stored
      // data instead of emptying itself.
      final dev = link.deviceName;
      if (dev != _loadedFor && !loading) _load();
    });
    // A sync lands AFTER the connect, so reloading only on connect leaves
    // these metrics computed from almost no data.
    _dataSub = Store.instance.changes.listen((rev) {
      if (rev != _loadedRevision && !loading) _load();
    });
    // Age changes the VO2max, strain and BioAge maths, so an edit on the
    // Device tab has to invalidate these cards. Unguarded on purpose: a
    // profile save is always a real change.
    _profileSub = Profile.instance.changes.listen((_) {
      if (!loading) _load();
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _dataSub?.cancel();
    _profileSub?.cancel();
    super.dispose();
  }

  /// The device whose data this page should show.
  ///
  /// The live connection when there is one, otherwise the last device that
  /// actually stored samples. Without the fallback a disconnected phone
  /// renders "No data yet" while holding a month of history, which reads as
  /// data loss rather than as being offline.
  /// Set once we have asked the store to name a device, so a store with no
  /// data does not trigger a lookup on every reload.
  bool _recoveredFromStore = false;

  /// Adopt a device the database knows about but the profile does not.
  ///
  /// This is the upgrade path: history synced before the profile persisted
  /// the advertised name would otherwise be invisible while disconnected,
  /// which looks exactly like losing it.
  Future<void> _recoverDeviceFromStore() async {
    final found = await Store.instance.lastSeenDevice();
    if (found == null || found.isEmpty || !mounted) return;
    // No address, and none is offered. `found` is an advertised NAME read out
    // of the samples table; passing it as the remoteId — which this did until
    // the profile's `bandId` became server-side identity — writes a mutable
    // display name into the field whose whole job is to survive a rename.
    await Profile.instance.rememberBand(null, null, displayName: found);
    if (mounted) await _load();
  }

  /// Resolved SYNCHRONOUSLY on purpose.
  ///
  /// The first frame must not await a platform channel: while it does, the
  /// page shows an indeterminate spinner, and a spinner is a permanently
  /// animating widget. Anything waiting for the UI to go quiet — a test's
  /// pumpAndSettle, or a user watching — waits forever.
  ///
  /// The profile is already loaded before runApp, so the remembered
  /// advertised name is available with no I/O at all.
  String _deviceForDisplay() {
    final live = link.deviceName;
    if (live.isNotEmpty) return live;
    return Profile.instance.bandDisplayName ?? '';
  }

  Future<void> _load() async {
    final dev = _deviceForDisplay();
    if (dev.isEmpty) {
      if (mounted) setState(() => loading = false);
      // A band was paired once but we have no name to read its history
      // under — history synced before the profile recorded the advertised
      // name. Ask the database, AFTER releasing this frame so the empty
      // state renders rather than a spinner that never settles.
      //
      // Gated on a band having been paired at all: with no pairing there is
      // nothing orphaned to recover, and no reason to touch the database on
      // startup.
      if (Profile.instance.bandId != null && !_recoveredFromStore) {
        _recoveredFromStore = true;
        unawaited(_recoverDeviceFromStore());
      }
      return;
    }
    if (!Profile.instance.loaded) await Profile.instance.load();

    final since = DateTime.now().subtract(const Duration(days: 14));
    final todayStart = DateTime.now().copyWith(
        hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);

    // Raised from the 5,000 default. At a 5-minute sampling interval a
    // 14-day window is already ~4,000 rows before the band's 15-slot history
    // records are added, so the default was reached in ordinary use.
    const hrWindow = 25000;
    final h = await Store.instance
        .read(dev, 'heart_rate', since: since, limit: hrWindow);
    final clipped =
        await Store.instance.wasTruncated(dev, 'heart_rate', since: since, limit: hrWindow);
    final o = await Store.instance.read(dev, 'spo2', since: since);
    final v = await Store.instance.read(dev, 'hrv', since: since);
    final t = await Store.instance.read(dev, 'temperature', since: since);
    // Daily totals are stamped at midnight of their own day, so the window
    // has to start at todayStart itself, not later.
    final st = await Store.instance.read(dev, 'steps', since: todayStart);
    final ca = await Store.instance.read(dev, 'calories', since: todayStart);
    final di = await Store.instance.read(dev, 'distance', since: todayStart);
    final am =
        await Store.instance.read(dev, 'active_minutes', since: todayStart);

    final rest = restingHeartRate(h);
    final hrToday = h.where((s) => s.at.isAfter(todayStart)).toList();

    if (!mounted) return;
    setState(() {
      hr = h;
      spo2 = o;
      hrv = v;
      temp = t;
      steps = st.isEmpty ? 0 : st.last.value;
      kcal = ca.isEmpty ? 0 : ca.last.value;
      km = di.isEmpty ? 0 : di.last.value;
      activeMin = am.isEmpty ? 0 : am.last.value;
      resting = rest;
      recoveryScore = recovery(hrvHistory: v, hrHistory: h);
      strainScore =
          strain(hrToday: hrToday, age: Profile.instance.age, resting: rest);
      loading = false;
      _clipped = clipped;
      _loadedFor = dev;
      _loadedRevision = Store.instance.revision;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return StreamBuilder<void>(
      stream: link.changes,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The date, and no "Today" heading: the tab above this
                    // page already says Today, and printing it twice is the
                    // same word twice.
                    Text(DateFormat('EEEE, d MMMM').format(DateTime.now()),
                        style: t.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              _connectionChip(t),
            ]),
            const SizedBox(height: 16),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (hr.isEmpty && spo2.isEmpty)
              EmptyState(
                icon: Icons.watch_outlined,
                title: 'No data yet',
                hint: link.connected
                    ? 'Pull down to sync your band\'s stored history.'
                    : 'Connect your band on the Device tab, then sync.',
              )
            else ...[
              // Stored data shown while disconnected must not read as live.
              if (!link.connected) ...[
                _offlineNotice(t),
                const SizedBox(height: 12),
              ],
              if (_clipped) ...[
                _clippedNotice(t),
                const SizedBox(height: 12),
              ],
              if (fd.nothingConfirmedOnV5) ...[
                _unverifiedBanner(t),
                const SizedBox(height: 12),
              ],
              _activityCard(t),
              const SizedBox(height: 12),
              _readinessRow(t),
              const SizedBox(height: 12),
              // No footnote. The provenance note that sat under this graph
              // was removed at the user's request; the UNVERIFIED warning it
              // also carried is not lost, because _unverifiedBanner above
              // already states it at the top of the page whenever
              // `fd.nothingConfirmedOnV5` holds.
              _metricCard(t, 'Heart Rate', hr, 'bpm', kBad,
                  extra: resting == null
                      ? null
                      : '${resting!.display} bpm resting'),
              const SizedBox(height: 12),
              _metricCard(t, 'Blood Oxygen', spo2, '%', kAccent),
              const SizedBox(height: 12),
              if (temp.isNotEmpty)
                _metricCard(t, 'Skin Temperature', temp,
                    Units.of(Profile.instance).temperatureUnit, kWarn,
                    convert: Units.of(Profile.instance).temperatureValue)
              else
                _temperatureUnavailable(t),
            ],
          ],
        ),
      ),
    );
  }

  /// Says the window was clipped, rather than letting the derived numbers
  /// speak as though it was not.
  Widget _clippedNotice(ThemeData t) => Card(
        color: kWarn.withValues(alpha: 0.10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.filter_alt_outlined, size: 18, color: kWarn),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'More readings exist than fit in one read, so resting heart '
                'rate, recovery and strain below are computed from the most '
                'recent part of the window rather than all of it.',
                style: t.textTheme.bodySmall?.copyWith(color: kWarn),
              ),
            ),
          ]),
        ),
      );

  Widget _connectionChip(ThemeData t) {
    final on = link.connected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: (on ? kAccent : kMuted).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(on ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            size: 14, color: on ? kAccent : kMuted),
        const SizedBox(width: 6),
        Text(on ? (link.deviceName.isEmpty ? 'Connected' : link.deviceName) : 'Offline',
            style: t.textTheme.labelSmall
                ?.copyWith(color: on ? kAccent : kMuted)),
      ]),
    );
  }

  Widget _activityCard(ThemeData t) => SectionCard(
        title: 'Activity',
        subtitle: 'today',
        // Steps/distance/calories come from opcode 0x51 (per-day totals). If
        // they are all zero we have simply not synced yet — say that rather
        // than drawing empty rings, which read as "you walked nowhere".
        child: (steps == 0 && kcal == 0 && km == 0)
            ? Row(children: [
                const Icon(Icons.directions_walk, color: kMuted, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'No activity synced for today yet. Press Sync history on '
                    'the Device tab — the band keeps a running daily total.',
                    style: t.textTheme.bodySmall?.copyWith(color: kMuted),
                  ),
                ),
              ])
            : Builder(builder: (context) {
                final g = Profile.instance.goals;
                final u = Units.of(Profile.instance);
                return Row(children: [
          ActivityRings(
              steps: steps,
              stepGoal: g.steps.toDouble(),
              kcal: kcal,
              kcalGoal: g.kcal.toDouble(),
              km: km,
              kmGoal: g.km),
          const SizedBox(width: 22),
          Expanded(
            child: Column(children: [
              _goalRow(t, 'Steps', steps.round().toString(),
                  NumberFormat.decimalPattern().format(g.steps), kAccent),
              const SizedBox(height: 10),
              _goalRow(t, 'Calories', kcal.toStringAsFixed(0), '${g.kcal}',
                  kGreen),
              const SizedBox(height: 10),
              _goalRow(t, 'Distance', u.distanceValue(km),
                  u.distance(g.km), kWarn),
              if (activeMin > 0) ...[
                const SizedBox(height: 10),
                _goalRow(t, 'Active', '${activeMin.round()}',
                    '${g.activeMinutes} min', kAccent2),
              ],
            ]),
          ),
        ]);
              }),
      );

  Widget _goalRow(
          ThemeData t, String label, String value, String goal, Color c) =>
      Row(children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
            child: Text(label,
                style: t.textTheme.bodySmall?.copyWith(color: kMuted))),
        Text(value, style: t.textTheme.bodyMedium),
        Text(' / $goal',
            style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
      ]);

  Widget _readinessRow(ThemeData t) => Row(children: [
        Expanded(
          child: SectionCard(
            title: 'Recovery',
            child: EstimateTile(
              label: recoveryScore == null ? '' : recoveryScore!.basis,
              estimate: recoveryScore,
              emptyHint: 'needs 4+ nights of HRV',
              color: kAccent,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SectionCard(
            title: 'Strain',
            child: EstimateTile(
              label: strainScore == null ? '' : 'of 21',
              estimate: strainScore,
              emptyHint: 'needs more of today\'s HR',
              color: kAccent2,
            ),
          ),
        ),
      ]);

  /// Says these numbers are from storage, not from the band right now.
  ///
  /// Showing a month of history offline is right — it is the user's data and
  /// the phone has it. Showing it without saying the band is disconnected is
  /// not: "latest 85 bpm" would imply a current reading when it could be
  /// hours old.
  Widget _offlineNotice(ThemeData t) {
    final newest = [
      for (final s in [hr, spo2, hrv, temp])
        if (s.isNotEmpty) s.last.at
    ];
    newest.sort();
    final stamp = newest.isEmpty
        ? null
        : DateFormat('d MMM, HH:mm').format(newest.last);
    return Card(
      color: t.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.cloud_off, size: 18, color: kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              stamp == null
                  ? 'Offline — showing data stored on this phone.'
                  : 'Offline — showing stored data. Newest reading $stamp. '
                      'Connect on the Device tab to sync anything since.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted),
            ),
          ),
        ]),
      ),
    );
  }

  /// A standing warning while no finding has been confirmed on a V5.
  ///
  /// This app inherits its decoders from a different band. Inherited offsets
  /// do not fail loudly — they produce numbers that look entirely reasonable.
  /// So the caveat stays on screen until something is actually verified here,
  /// rather than being a one-time dialog the user dismisses and forgets.
  Widget _unverifiedBanner(ThemeData t) => Card(
        color: t.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.science_outlined,
                size: 18, color: t.colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Unverified on the V5',
                        style: t.textTheme.titleSmall?.copyWith(
                            color: t.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      'Every decoder here was measured on a JCVital Pro V8. '
                      'The V5 is undocumented, and a wrong field offset '
                      'produces believable values, not errors. Treat these '
                      'numbers as provisional until checked against the '
                      'vendor app. Lab \u2192 Findings lists what to verify.',
                      style: t.textTheme.bodySmall?.copyWith(
                          color: t.colorScheme.onErrorContainer),
                    ),
                  ]),
            ),
          ]),
        ),
      );

  Widget _metricCard(
    ThemeData t,
    String title,
    List<Sample> data,
    String unit,
    Color colour, {
    String? extra,
    String? footnote,
    /// Applied to displayed values only. Storage stays metric; see [Units].
    double Function(double)? convert,
  }) {
    final f = convert ?? (double v) => v;
    final source =
        convert == null ? data : [for (final s in data) Sample(s.at, f(s.value))];
    final recent =
        source.length > 120 ? source.sublist(source.length - 120) : source;
    final last = source.isEmpty ? null : source.last;
    final vals = source.map((s) => s.value).toList();
    final avg = vals.isEmpty
        ? null
        : vals.reduce((a, b) => a + b) / vals.length;
    return SectionCard(
      title: title,
      subtitle: last == null
          ? null
          : 'last reading ${DateFormat.Hm().format(last.at)}',
      child: Column(children: [
        Sparkline(recent.map((s) => s.value).toList(), color: colour),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          BigStat(
              last == null
                  ? '—'
                  : (unit == '°C'
                      ? last.value.toStringAsFixed(1)
                      : last.value.round().toString()),
              unit,
              'latest',
              color: colour),
          BigStat(
              avg == null
                  ? '—'
                  : (unit == '°C'
                      ? avg.toStringAsFixed(1)
                      : avg.round().toString()),
              unit,
              'average'),
          if (extra != null)
            Flexible(
              child: Text(extra,
                  textAlign: TextAlign.right,
                  style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
            ),
        ]),
        if (footnote != null) ...[
            const SizedBox(height: 8),
            Text(footnote,
                style: t.textTheme.bodySmall?.copyWith(
                    color: kMuted, fontSize: 11, height: 1.35)),
          ],
        ]),
    );
  }

  /// Temperature is the one metric the band withholds until background
  /// monitoring is switched on, and an empty chart would read as a broken
  /// sensor. Say what is actually happening instead.
  Widget _temperatureUnavailable(ThemeData t) => SectionCard(
        title: 'Skin Temperature',
        subtitle: 'nothing recorded yet',
        tint: kCardAlt,
        child: Row(children: [
          const Icon(Icons.thermostat, color: kMuted, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'The band returned "nothing stored" for temperature. That is a '
              'background-monitoring setting, not a missing sensor — enabling '
              'it writes to the band, so it is on the Device tab behind a '
              'confirmation.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted),
            ),
          ),
        ]),
      );
}
