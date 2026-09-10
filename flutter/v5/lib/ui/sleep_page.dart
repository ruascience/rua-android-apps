import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../analytics/sleep.dart';
import '../ble/band_link.dart';
import '../data/store.dart';
import '../protocol/jstyle.dart' as j;
import 'kit.dart';

const _stageColour = {
  j.SleepStage.awake: Color(0xFFF2F4F7),
  j.SleepStage.light: Color(0xFF9B5CF0),
  j.SleepStage.deep: Color(0xFF5B4BE8),
};

/// Sleep detail, following the vendor's screen: score, debt insight, duration
/// tiles, hypnogram, stage breakdown with ideal ranges, an overview block, and
/// per-metric overnight charts.
class SleepPage extends StatefulWidget {
  const SleepPage({super.key});
  @override
  State<SleepPage> createState() => _SleepPageState();
}

class _SleepPageState extends State<SleepPage> {
  final link = BandLink.instance;

  List<SleepNight> nights = const [];
  List<SleepNight> naps = const [];
  int index = 0; // 0 = most recent
  List<Sample> hr = const [], spo2 = const [], hrv = const [];
  bool loading = true;

  /// The shell uses an IndexedStack, so this page is built once at startup —
  /// before any band is connected. Without this it would show "no sleep"
  /// forever even after a successful sync.
  String _loadedFor = '';
  int _loadedRevision = -1;
  StreamSubscription<void>? _linkSub;
  StreamSubscription<int>? _dataSub;

  @override
  void initState() {
    super.initState();
    load();
    _linkSub = link.changes.listen((_) {
      final dev = link.deviceName;
      if (dev.isNotEmpty && dev != _loadedFor && !loading) load();
    });
    // A sync lands AFTER the connect, so reloading only on connect leaves
    // these metrics computed from almost no data.
    _dataSub = Store.instance.changes.listen((rev) {
      if (rev != _loadedRevision && !loading) load();
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _dataSub?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final dev = link.deviceName;
    if (dev.isEmpty) {
      if (mounted) setState(() => loading = false);
      return;
    }
    final since = DateTime.now().subtract(const Duration(days: 30));
    final segs = await Store.instance.readSleepSegments(dev, since: since);
    final h = await Store.instance.read(dev, 'heart_rate', since: since);
    final o = await Store.instance.read(dev, 'spo2', since: since);
    final v = await Store.instance.read(dev, 'hrv', since: since);
    if (!mounted) return;
    setState(() {
      final all = buildNights(segs);
      // A short fragment must not be selected as "last night".
      nights = nightsOnly(all).reversed.toList(); // newest first
      naps = napsOnly(all).reversed.toList();
      hr = h;
      spo2 = o;
      hrv = v;
      index = 0;
      loading = false;
      _loadedFor = link.deviceName;
      _loadedRevision = Store.instance.revision;
    });
  }

  SleepNight? get night =>
      nights.isEmpty ? null : nights[index.clamp(0, nights.length - 1)];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (loading) return const Center(child: CircularProgressIndicator());
    final n = night;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _header(t, n),
          const SizedBox(height: 16),
          if (n == null)
            EmptyState(
              icon: Icons.bedtime_outlined,
              title: 'No sleep recorded',
              hint: 'Wear the band overnight, then press Sync history on the '
                  'Device tab. Sleep is stored on the band and only arrives '
                  'with a sync.',
            )
          else ...[
            _debtCard(t, n),
            const SizedBox(height: 12),
            _durationTiles(t, n),
            const SizedBox(height: 12),
            _hypnogramCard(t, n),
            const SizedBox(height: 12),
            _stagesCard(t, n),
            const SizedBox(height: 12),
            _overviewCard(t, n),
            const SizedBox(height: 12),
            _metricCard(t, 'Heart Rate', hr, n, 'bpm', kBad, rateSleepingHr,
                lowIsBad: false),
            const SizedBox(height: 12),
            _metricCard(t, 'Blood Oxygen', spo2, n, '%', const Color(0xFF3DDC84),
                rateSpo2),
            const SizedBox(height: 12),
            _metricCard(t, 'HRV', hrv, n, 'ms', const Color(0xFF37AEE2), rateHrv),
            const SizedBox(height: 12),
            _napsCard(t),
          ],
        ],
      ),
    );
  }

  Widget _header(ThemeData t, SleepNight? n) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // No "Sleep" heading — the tab above says it, and the score
            // below is what the page is actually for.
            if (n != null)
              Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic, children: [
                Text('${n.score}',
                    style: t.textTheme.headlineMedium?.copyWith(
                        color: kAccent, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                Text(n.scoreLabel,
                    style: t.textTheme.titleSmall?.copyWith(color: kMuted)),
              ]),
            if (n != null)
              Row(
                  children: List.generate(
                      5,
                      (i) => Icon(
                          i < n.stars ? Icons.star : Icons.star_border,
                          size: 15,
                          color: i < n.stars ? kAccent2 : kMuted))),
          ]),
        ),
        if (nights.length > 1) ...[
          IconButton(
            onPressed: index < nights.length - 1
                ? () => setState(() => index++)
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          // The night being shown, and the only thing on this page that says
          // WHICH night. It was bodySmall in muted grey — smaller than the
          // chevrons either side of it — so the page read as "last night"
          // whichever night you had paged back to.
          Text(n == null ? '' : DateFormat.MMMd().format(n.start),
              style: t.textTheme.titleLarge?.copyWith(
                  color: kText, fontWeight: FontWeight.w600)),
          IconButton(
            onPressed: index > 0 ? () => setState(() => index--) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ] else if (n != null)
          Text(DateFormat.MMMd().format(n.start),
              style: t.textTheme.titleLarge?.copyWith(
                  color: kText, fontWeight: FontWeight.w600)),
      ]);

  Widget _debtCard(ThemeData t, SleepNight n) {
    final d = n.debt();
    final none = d.inMinutes == 0;
    return Card(
      color: const Color(0xFF0E2A24),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.nightlight_round, color: kAccent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  none
                      ? 'You met your sleep target'
                      : 'Sleep debt is ${formatHm(d)}',
                  style: t.textTheme.titleMedium?.copyWith(color: kAccent)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(
            none
                ? 'Keep the same schedule — consistent timing matters as much '
                    'as total hours.'
                : 'Reduce screen time before bed and avoid bright light. Keep '
                    'caffeine and alcohol away from bedtime. Moderate exercise '
                    'such as brisk walking helps increase deep sleep.',
            style: t.textTheme.bodySmall?.copyWith(color: kMuted),
          ),
        ]),
      ),
    );
  }

  Widget _durationTiles(ThemeData t, SleepNight n) => Row(children: [
        Expanded(
          child: SectionCard(
            title: 'Total Sleep Time',
            child: BigStat(formatHm(n.totalSleep), '', _ratingOf(n.totalSleep),
                color: kAccent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SectionCard(
            title: 'In Bed',
            child: BigStat(formatHm(n.inBed), '',
                '${DateFormat.Hm().format(n.start)} – ${DateFormat.Hm().format(n.end)}',
                color: kAccent2),
          ),
        ),
      ]);

  String _ratingOf(Duration d) {
    final h = d.inMinutes / 60;
    if (h >= 7 && h <= 9) return 'Good';
    return h < 7 ? 'Short' : 'Long';
  }

  Widget _hypnogramCard(ThemeData t, SleepNight n) => SectionCard(
        title: 'Sleep Duration',
        subtitle:
            '${DateFormat.Hm().format(n.start)} – ${DateFormat.Hm().format(n.end)}',
        child: Column(children: [
          SizedBox(
            height: 132,
            width: double.infinity,
            child: CustomPaint(painter: _HypnoPainter(n)),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(DateFormat.Hm().format(n.start),
                style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
            Text(DateFormat.Hm().format(n.end),
                style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
          ]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              for (final c in [
                j.SleepStage.awake,
                j.SleepStage.light,
                j.SleepStage.deep
              ])
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: _stageColour[c],
                          borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 6),
                  Text(j.SleepStage.label(c),
                      style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
                ]),
            ],
          ),
        ]),
      );

  Widget _stagesCard(ThemeData t, SleepNight n) => SectionCard(
        title: 'Sleep Stages',
        subtitle: 'shaded band = typical adult range',
        child: Column(children: [
          _stageRow(t, n, j.SleepStage.awake, 'Awake', null),
          const SizedBox(height: 14),
          _stageRow(t, n, j.SleepStage.light, 'Light', const (45.0, 60.0)),
          const SizedBox(height: 14),
          _stageRow(t, n, j.SleepStage.deep, 'Deep', const (13.0, 25.0)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: kCardAlt, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.info_outline, size: 15, color: kMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your band reports three states. The vendor app shows a '
                  'fourth (REM) that it derives on the phone — the band never '
                  'sends it, so we do not invent one.',
                  style: t.textTheme.labelSmall?.copyWith(color: kMuted),
                ),
              ),
            ]),
          ),
        ]),
      );

  Widget _stageRow(
      ThemeData t, SleepNight n, int code, String label, (double, double)? ideal) {
    final mins = n.stageMinutes[code] ?? 0;
    final pct = n.pct(code);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: t.textTheme.bodyMedium),
        const SizedBox(width: 8),
        if (ideal != null)
          Text('${pct.round()}%',
              style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
        const Spacer(),
        Text(formatHm(Duration(minutes: mins.round())),
            style: t.textTheme.bodyMedium),
      ]),
      const SizedBox(height: 6),
      SizedBox(
        height: 14,
        child: CustomPaint(
          size: const Size(double.infinity, 14),
          painter: _StageBarPainter(
              pct / 100, _stageColour[code]!, ideal),
        ),
      ),
    ]);
  }

  Widget _overviewCard(ThemeData t, SleepNight n) => SectionCard(
        title: 'Sleep Overview',
        child: Column(children: [
          _bar(t, 'Total Sleep Time', formatHm(n.totalSleep),
              n.totalSleep.inMinutes / (9 * 60)),
          _bar(t, 'In Bed Duration', formatHm(n.inBed), n.inBed.inMinutes / (9 * 60)),
          _bar(t, 'Sleep efficiency', '${n.efficiency.round()}%',
              n.efficiency / 100),
          _bar(t, 'Sleep latency', formatHm(n.latency),
              1 - (n.latency.inMinutes / 60).clamp(0.0, 1.0)),
          _bar(t, 'Sleep debt', formatHm(n.debt()),
              1 - (n.debt().inMinutes / 240).clamp(0.0, 1.0)),
          // A gap means a segment never arrived. Total Sleep Time is then
          // genuinely lower than the night was, and the user deserves to know
          // that is a sync gap rather than a bad night.
          if (n.unaccounted.inMinutes >= 10)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: kWarn.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(Icons.help_outline, size: 16, color: kWarn),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${formatHm(n.unaccounted)} of this night never reached '
                    'the app — the band did not return one of its sleep '
                    'segments. Total Sleep Time is low by roughly that much. '
                    'Syncing again may recover it.',
                    style: t.textTheme.labelSmall?.copyWith(color: kMuted),
                  ),
                ),
              ]),
            ),
        ]),
      );

  Widget _bar(ThemeData t, String label, String value, double frac) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(children: [
          Row(children: [
            Expanded(
                child: Text(label,
                    style: t.textTheme.bodyMedium?.copyWith(color: kText))),
            Text(value, style: t.textTheme.bodyMedium),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: frac.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: kCardAlt,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF9DB2FF)),
            ),
          ),
        ]),
      );

  Widget _metricCard(
    ThemeData t,
    String title,
    List<Sample> data,
    SleepNight n,
    String unit,
    Color colour,
    Rating Function(double) rate, {
    bool lowIsBad = true,
  }) {
    final s = summarise(data, n.start, n.end, rate, lowIsBad: lowIsBad);
    final inWindow = data
        .where((x) => !x.at.isBefore(n.start) && !x.at.isAfter(n.end))
        .map((x) => x.value)
        .toList();
    if (s == null) {
      return SectionCard(
        title: title,
        subtitle: 'overnight',
        child: Text('No $title readings during this night.',
            style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
      );
    }
    return SectionCard(
      title: title,
      subtitle: 'overnight',
      child: Column(children: [
        Sparkline(inWindow, color: colour, height: 64),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
              child: _ratingTile(t, s.avg!, unit, 'Avg', s.avgRating, colour)),
          const SizedBox(width: 12),
          Expanded(
              child: _ratingTile(
                  t, s.lowest!, unit, 'Lowest', s.lowestRating, colour)),
        ]),
      ]),
    );
  }

  Widget _ratingTile(ThemeData t, double v, String unit, String label,
      Rating r, Color colour) {
    final c = switch (r) {
      Rating.optimal => const Color(0xFF2FA84F),
      Rating.good => kWarn,
      Rating.needsAttention => kBad,
      Rating.unknown => kMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
          color: const Color(0xFF0B0E12),
          borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(v.round().toString(),
                  style: t.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text(' $unit',
                  style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
            ]),
        Text(label, style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
              color: c.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20)),
          child: Text(r.label,
              style: t.textTheme.labelSmall?.copyWith(color: c)),
        ),
      ]),
    );
  }

  Widget _napsCard(ThemeData t) => SectionCard(
        title: 'Naps',
        // These come from a 30-day window, so "today" was simply wrong.
        subtitle: naps.isEmpty ? null : '${naps.length} in the last 30 days',
        child: naps.isNotEmpty
            ? Column(
                children: naps
                    .map((n) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                  '${DateFormat.Hm().format(n.start)} – '
                                  '${DateFormat.Hm().format(n.end)}',
                                  style: t.textTheme.bodyMedium),
                              Text(formatHm(n.inBed),
                                  style: t.textTheme.bodyMedium
                                      ?.copyWith(color: kAccent2)),
                            ],
                          ),
                        ))
                    .toList(),
              )
            : Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(children: [
              Icon(Icons.airline_seat_individual_suite_outlined,
                  size: 34, color: kMuted),
              const SizedBox(height: 8),
              Text('No naps',
                  style: t.textTheme.bodySmall?.copyWith(color: kMuted)),
              const SizedBox(height: 4),
              Text('A sleep block under an hour counts as a nap.',
                  style: t.textTheme.labelSmall?.copyWith(color: kMuted)),
            ]),
          ),
        ),
      );

}

/// Hypnogram: one lane per stage, blocks drawn along the night.
class _HypnoPainter extends CustomPainter {
  final SleepNight n;
  _HypnoPainter(this.n);

  // Awake on top, then light, then deep — the conventional ordering.
  static const lanes = [
    j.SleepStage.awake,
    j.SleepStage.light,
    j.SleepStage.deep
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final totalMs = n.end.difference(n.start).inMilliseconds;
    if (totalMs <= 0) return;
    final laneH = size.height / lanes.length;

    for (var i = 0; i < lanes.length; i++) {
      final y = i * laneH;
      canvas.drawRect(
          Rect.fromLTWH(0, y + laneH * 0.18, size.width, laneH * 0.64),
          Paint()..color = _stageColour[lanes[i]]!.withValues(alpha: 0.08));
    }

    for (final b in n.blocks) {
      final lane = lanes.indexOf(b.code);
      if (lane < 0) continue;
      final x0 = b.start.difference(n.start).inMilliseconds / totalMs * size.width;
      final x1 = b.end.difference(n.start).inMilliseconds / totalMs * size.width;
      final y = lane * laneH;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, y + laneH * 0.18, math.max(x1, x0 + 1.5),
            y + laneH * 0.82),
        const Radius.circular(2),
      );
      canvas.drawRRect(r, Paint()..color = _stageColour[b.code]!);
    }
  }

  @override
  bool shouldRepaint(_HypnoPainter old) => old.n != n;
}

/// Stage bar with an optional shaded "typical range" band behind it.
class _StageBarPainter extends CustomPainter {
  final double frac;
  final Color colour;
  final (double, double)? ideal;
  _StageBarPainter(this.frac, this.colour, this.ideal);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, r),
        Paint()..color = kCardAlt);

    if (ideal != null) {
      final (lo, hi) = ideal!;
      canvas.drawRect(
          Rect.fromLTRB(size.width * lo / 100, 0, size.width * hi / 100,
              size.height),
          Paint()..color = Colors.white.withValues(alpha: 0.16));
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * frac.clamp(0.0, 1.0), size.height),
          r),
      Paint()..color = colour,
    );
  }

  @override
  bool shouldRepaint(_StageBarPainter old) =>
      old.frac != frac || old.ideal != ideal;
}
