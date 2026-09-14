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

  /// The selected day's heart rate, and nothing before it.
  ///
  /// Separate from [hr] on purpose. [hr] is a 14-day window because resting
  /// heart rate and recovery need a fortnight to say anything; the ribbon
  /// draws ONE day against a fixed 24-hour axis. Feeding it the fortnight
  /// drew fourteen days squeezed onto one day's axis, and the caption then
  /// reported the fortnight's peak as if it had happened today — "peak
  /// 110 bpm at 18:20" read at 12:48.
  List<Sample> hrDay = const [];

  /// Sleep actually recorded overlapping the selected day.
  List<DateTimeRange> asleep = const [];
  /// Daily totals, or null when the band has no record for this day.
  ///
  /// Nullable on purpose. These were `double` defaulting to 0, so a day the
  /// band never reported and a day it reported as genuinely zero drew the
  /// identical "Steps 0 / 10,000" — an unsynced day reading as a sedentary
  /// one. The band stores one 0x51 record per day and syncs them in a batch;
  /// a missing record is common and is not a measurement of zero.
  double? steps, kcal, km, activeMin;
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

  /// The day being shown. Home was fixed to the current one, so "how was
  /// Tuesday" — the rings, recovery and strain for a past day — could not be
  /// asked at all, even though every reading needed to answer it was already
  /// on the phone.
  DateTime _day = DateTime.now();

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year && _day.month == now.month && _day.day == now.day;
  }

  DateTime get _dayStart => DateTime(_day.year, _day.month, _day.day);
  DateTime get _dayEnd => _dayStart.add(const Duration(days: 1));

  Future<void> _stepDay(int days) async {
    final next = _dayStart.add(Duration(days: days));
    // Never forward past today: there is no data there, and an empty screen
    // for tomorrow reads as a fault rather than as a boundary.
    if (next.isAfter(DateTime.now())) return;
    setState(() => _day = next);
    await _load();
  }

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

    // The 14-day window still ends at the selected day: recovery compares a
    // night against the fortnight BEFORE it, and a window that always ended
    // today would compare a past day against readings that came after it.
    final since = _dayStart.subtract(const Duration(days: 14));
    final todayStart = _dayStart;

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

    // Sleep for the shaded band. Read from the evening BEFORE the day: a
    // night that starts at 23:40 belongs to the day it ends on as much as
    // the one it began on, and clipping happens in the painter.
    final segs = await Store.instance.readSleepSegments(dev,
        since: _dayStart.subtract(const Duration(days: 1)));

    // Everything is read from `since` forward, so the selected day's window
    // has to be closed at its own end rather than running to now.
    List<Sample> upToDay(List<Sample> xs) =>
        xs.where((s) => s.at.isBefore(_dayEnd)).toList();
    final rest = restingHeartRate(upToDay(h));
    List<Sample> onDay(List<Sample> xs) => xs
        .where((s) => !s.at.isBefore(todayStart) && s.at.isBefore(_dayEnd))
        .toList();
    final hrToday = onDay(h);
    final nights = segs
        .where((g) => g.end.isAfter(_dayStart) && g.start.isBefore(_dayEnd))
        .map((g) => DateTimeRange(start: g.start, end: g.end))
        .toList();

    if (!mounted) return;
    setState(() {
      hr = upToDay(h);
      hrDay = hrToday;
      asleep = nights;
      spo2 = upToDay(o);
      hrv = upToDay(v);
      temp = upToDay(t);
      final stD = onDay(st), caD = onDay(ca), diD = onDay(di), amD = onDay(am);
      steps = stD.isEmpty ? null : stD.last.value;
      kcal = caD.isEmpty ? null : caD.last.value;
      km = diD.isEmpty ? null : diD.last.value;
      activeMin = amD.isEmpty ? null : amD.last.value;
      resting = rest;
      recoveryScore =
          recovery(hrvHistory: upToDay(v), hrHistory: upToDay(h));
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
                    Row(children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Previous day',
                        onPressed: () => _stepDay(-1),
                        icon: const Icon(Icons.chevron_left, size: 20),
                      ),
                      Flexible(
                        child: GestureDetector(
                          // Tapping the date returns to today, which is the
                          // one navigation anybody wants after browsing back.
                          onTap: _isToday
                              ? null
                              : () async {
                                  setState(() => _day = DateTime.now());
                                  await _load();
                                },
                          child: Text(
                            _isToday
                                ? DateFormat('EEEE, d MMMM').format(_day)
                                : DateFormat('EEE, d MMM').format(_day),
                            style: t.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Next day',
                        // Disabled rather than hidden: a control that vanishes
                        // at the edge moves everything beside it.
                        onPressed: _isToday ? null : () => _stepDay(1),
                        icon: const Icon(Icons.chevron_right, size: 20),
                      ),
                      if (!_isToday)
                        TextButton(
                          onPressed: () async {
                            setState(() => _day = DateTime.now());
                            await _load();
                          },
                          child: const Text('Today'),
                        ),
                    ]),
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

              // The day itself, as one continuous trace. This is the anchor
              // of the screen: a day is a continuous thing and the band
              // records it continuously, so it is drawn that way rather than
              // reduced to a latest-value tile with a sparkline beside it.
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Lab('Heart rate · this day'),
                if (hrDay.isNotEmpty)
                  Lab('${hrDay.last.value.round()} bpm at '
                      '${DateFormat.Hm().format(hrDay.last.at)}', color: kBad),
              ]),
              const SizedBox(height: 6),
              DayRibbon(
                  samples: hrDay, day: _day, colour: kBad, asleep: asleep),
              const SizedBox(height: 6),
              Basis(_ribbonCaption()),
              const SizedBox(height: 18),

              // The three derived figures, each printing the sentence the
              // analytics already computed about where it came from.
              RuleGrid(children: [
                _derived('Recovery', recoveryScore,
                    empty: 'needs 4+ nights of HRV'),
                _derived('Strain', strainScore,
                    empty: 'needs more of today\'s HR', suffix: ' / 21'),
                _derived('Resting', resting, empty: 'wear it overnight'),
              ]),
              const SizedBox(height: 18),

              const Lab('Activity'),
              const SizedBox(height: 10),
              _activityBars(),
              const SizedBox(height: 20),

              const Lab('Also measured'),
              const SizedBox(height: 10),
              _alsoMeasured(),
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

  /// What the trace shows beyond its own shape: when the peak was, and that
  /// the shaded band is sleep rather than an axis decoration.
  String _ribbonCaption() {
    if (hrDay.isEmpty) {
      // The fortnight may still hold readings; say which is empty, because
      // "no data" on a day the band was worn is a different problem from a
      // band that has never synced.
      return hr.isEmpty
          ? 'No heart rate recorded.'
          : 'No heart rate recorded on this day.';
    }
    var peak = hrDay.first;
    for (final s in hrDay) {
      if (s.value > peak.value) peak = s;
    }
    final shading = asleep.isEmpty ? '' : 'Shaded — asleep. ';
    return '$shading${hrDay.length} readings, drawn as the 5-minute range '
        'with its median. Peak ${peak.value.round()} bpm at '
        '${DateFormat.Hm().format(peak.at)}.';
  }

  /// A derived figure and the sentence it carries.
  ///
  /// The basis line is not decoration: these numbers are computed on this
  /// phone from a window of samples that is often short, and the app already
  /// knew how to say so ("lowest sustained 25 s during 00:00–06:00"). Printing
  /// it under the figure is the difference between a reading and a claim.
  Widget _derived(String label, Estimate? e, {required String empty, String suffix = ''}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Lab(label),
        const SizedBox(height: 3),
        if (e == null) ...[
          Figure('—', size: 30, color: kMuted),
          const SizedBox(height: 3),
          Basis(empty),
        ] else ...[
          Figure(e.display, unit: suffix.isEmpty ? e.unit : suffix, size: 30),
          const SizedBox(height: 3),
          Expanded(child: Basis(e.basis)),
        ],
      ]);

  Widget _activityBars() {
    final g = Profile.instance.goals;
    final u = Units.of(Profile.instance);

    // An em dash, not a zero. The bar sits empty either way; the difference
    // is whether the app is claiming the day was sedentary.
    String shown(double? v, String Function(double) fmt) =>
        v == null ? '—' : fmt(v);
    double part(double? v, num goal) =>
        (v == null || goal == 0) ? 0 : v / goal;

    return Column(children: [
      GoalBar(
        label: 'Steps',
        value: shown(steps, (v) => NumberFormat.decimalPattern().format(v.round())),
        goal: '/ ${NumberFormat.decimalPattern().format(g.steps)}',
        fraction: part(steps, g.steps),
        colour: kAccent,
      ),
      const SizedBox(height: 11),
      GoalBar(
        label: 'Calories',
        value: shown(kcal, (v) => v.toStringAsFixed(0)),
        goal: '/ ${g.kcal}',
        fraction: part(kcal, g.kcal),
        colour: kGreen,
      ),
      const SizedBox(height: 11),
      GoalBar(
        label: 'Distance',
        value: shown(km, u.distanceValue),
        goal: '/ ${u.distance(g.km)}',
        fraction: part(km, g.km),
        colour: kWarn,
      ),
      if ((activeMin ?? 0) > 0) ...[
        const SizedBox(height: 11),
        GoalBar(
          label: 'Active',
          value: '${activeMin!.round()}',
          goal: '/ ${g.activeMinutes} min',
          fraction: part(activeMin, g.activeMinutes),
          colour: kAccent2,
        ),
      ],
      if (steps == null && kcal == null && km == null) ...[
        const SizedBox(height: 8),
        Basis(_isToday
            ? 'no activity record synced yet today — the band stores one '
                'per day; sync from the Band tab'
            : 'no activity record for this day'),
      ],
    ]);
  }

  /// The signals that are sampled occasionally rather than continuously.
  ///
  /// Last reading and its time, not a chart: at a handful of readings a day a
  /// sparkline draws a line between three points and implies a trend that is
  /// not there. The trend for these lives in Trends, over weeks.
  Widget _alsoMeasured() {
    final u = Units.of(Profile.instance);
    Widget tile(String label, List<Sample> data, String unit, Color c,
        {String Function(double)? fmt}) {
      final last = data.isEmpty ? null : data.last;
      return Container(
        decoration:
            BoxDecoration(border: Border(left: BorderSide(color: c, width: 2))),
        padding: const EdgeInsets.only(left: 9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (last == null)
            Figure('—', size: 22, color: kMuted)
          else
            Figure(fmt == null ? last.value.round().toString() : fmt(last.value),
                unit: unit, size: 22),
          const SizedBox(height: 1),
          Lab(last == null
              ? '$label none yet'
              : '$label ${DateFormat.Hm().format(last.at)}'),
        ]),
      );
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: tile('SpO₂', spo2, '%', kAccent)),
      const SizedBox(width: 10),
      Expanded(child: tile('HRV', hrv, 'ms', kGreen)),
      const SizedBox(width: 10),
      Expanded(
          child: tile('Skin', temp, u.temperatureUnit, kWarn,
              fmt: (v) => u.temperatureValue(v).toStringAsFixed(1))),
    ]);
  }

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

}
