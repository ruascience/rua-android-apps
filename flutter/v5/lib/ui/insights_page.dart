import 'dart:async';

import 'package:flutter/material.dart';

import '../analytics/metrics.dart';
import '../ble/band_link.dart';
import '../data/profile.dart';
import '../data/store.dart';
import 'kit.dart';

/// The premium modules: BioAge, VO2Max, Recovery, Strain and cycle tracking.
///
/// The vendor computes these on the phone too — the band transmits none of
/// them. Ours use published methods rather than the vendor's undisclosed ones,
/// so the numbers will differ. Each card states what produced it.
class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key});
  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  final link = BandLink.instance;
  final profile = Profile.instance;

  Estimate? resting, vo2, bio, rec, str;
  bool loading = true;

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
    if (!profile.loaded) await profile.load();
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
    final since = DateTime.now().subtract(const Duration(days: 60));
    final hr = await Store.instance.read(dev, 'heart_rate', since: since);
    final hrv = await Store.instance.read(dev, 'hrv', since: since);
    final todayStart = DateTime.now()
        .copyWith(hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);

    final r = restingHeartRate(hr);
    // VO2max needs the WAKING resting rate, not the overnight minimum.
    final w = wakingRestingHeartRate(hr);
    final v = vo2max(waking: w, age: profile.age);
    if (!mounted) return;
    setState(() {
      resting = r;
      vo2 = v;
      bio = bioAge(chronologicalAge: profile.age, vo2: v, hrv: hrv);
      rec = recovery(hrvHistory: hrv, hrHistory: hr);
      str = strain(
          hrToday: hr.where((s) => s.at.isAfter(todayStart)).toList(),
          age: profile.age,
          resting: r);
      loading = false;
      _loadedFor = dev;
      _loadedRevision = Store.instance.revision;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // No "Insights" heading — the tab above says it. The line below
          // is not a subtitle to it; it is the point of the page, and the
          // reason every number here carries a data-quality dot.
          Text('Derived on this phone from your band\'s data',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
          const SizedBox(height: 16),
          _bioAgeCard(t),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: SectionCard(
                title: 'VO₂max',
                child: EstimateTile(
                    label: vo2 == null ? '' : vo2!.unit,
                    estimate: vo2,
                    emptyHint: 'needs a resting HR',
                    color: kAccent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SectionCard(
                title: 'Resting HR',
                child: EstimateTile(
                    label: 'bpm',
                    estimate: resting,
                    emptyHint: 'wear overnight',
                    color: kBad),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: SectionCard(
                title: 'Recovery',
                child: EstimateTile(
                    label: 'of 100',
                    estimate: rec,
                    emptyHint: 'needs 4+ nights',
                    color: kAccent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SectionCard(
                title: 'Strain',
                child: EstimateTile(
                    label: 'of 21',
                    estimate: str,
                    emptyHint: 'needs today\'s HR',
                    color: kAccent2),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _bioAgeCard(ThemeData t) {
    final delta = bio == null ? null : bio!.value - profile.age;
    return SectionCard(
      title: 'Biological age',
      subtitle: 'fitness-weighted, not a clinical measure',
      child: Row(children: [
        Expanded(
          child: EstimateTile(
            label: bio == null ? '' : bio!.basis,
            estimate: bio,
            emptyHint: 'needs a resting HR or HRV history',
            color: delta == null
                ? kText
                : (delta <= 0 ? kAccent : kWarn),
          ),
        ),
        if (delta != null)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: (delta <= 0 ? kAccent : kWarn).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(children: [
              Text(
                  '${delta <= 0 ? "−" : "+"}${delta.abs().toStringAsFixed(1)}',
                  style: t.textTheme.titleLarge?.copyWith(
                      color: delta <= 0 ? kAccent : kWarn,
                      fontWeight: FontWeight.w700)),
              Text('vs your ${profile.age}',
                  style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
            ]),
          ),
      ]),
    );
  }

}
