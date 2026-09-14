import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ble/band_link.dart';
import '../data/store.dart';
import 'kit.dart';

/// Signals the band reports that are not measurements of what they are named.
///
/// Blood pressure is the reason this section exists. The band sends systolic
/// and diastolic on every sync and the app stored both and showed neither —
/// which is the one option that cannot be defended either way, because the
/// data exists and nobody decided what it is.
///
/// It is not dropped, because the readings are real data about the pulse
/// waveform and a study may want them. It is not shown beside heart rate,
/// because at equal visual weight it reads as equally real and somebody will
/// eventually make a medication decision on a number derived from a wrist
/// LED. It is here, behind a heading that says what it is, collapsed until
/// asked for, with the derivation stated on the same screen as the figures.
class ExperimentalSection extends StatefulWidget {
  const ExperimentalSection({super.key});
  @override
  State<ExperimentalSection> createState() => _ExperimentalSectionState();
}

class _ExperimentalSectionState extends State<ExperimentalSection> {
  List<Sample> _sys = const [], _dia = const [];
  bool _open = false;
  int _loadedRevision = -1;
  StreamSubscription<int>? _dataSub;
  StreamSubscription<void>? _linkSub;

  static const _days = 14;

  @override
  void initState() {
    super.initState();
    _load();
    _dataSub = Store.instance.changes.listen((rev) {
      if (rev != _loadedRevision) _load();
    });
    _linkSub = BandLink.instance.changes.listen((_) => _load());
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _linkSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final dev = BandLink.instance.deviceName.isNotEmpty
        ? BandLink.instance.deviceName
        : (await Store.instance.lastSeenDevice() ?? '');
    if (dev.isEmpty) return;
    final since = DateTime.now().subtract(const Duration(days: _days));
    final sys = await Store.instance.read(dev, 'systolic', since: since);
    final dia = await Store.instance.read(dev, 'diastolic', since: since);
    if (!mounted) return;
    setState(() {
      _sys = sys;
      _dia = dia;
      _loadedRevision = Store.instance.revision;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = _sys.length + _dia.length;
    final now = DateTime.now();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Icon(Icons.science_outlined, size: 16, color: kWarn),
            const SizedBox(width: 8),
            const Expanded(child: Lab('Experimental — not a measurement')),
            Text('$n readings',
                style: TextStyle(
                    fontFamily: kMono, fontSize: 11, color: kMuted)),
            Icon(_open ? Icons.expand_less : Icons.expand_more,
                size: 20, color: kMuted),
          ]),
        ),
      ),
      if (_open) ...[
        Container(
          decoration: BoxDecoration(
            color: kWarn.withValues(alpha: 0.08),
            border: Border.all(color: kWarn.withValues(alpha: 0.35)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Blood pressure',
                style: t.textTheme.titleSmall?.copyWith(color: kText)),
            const SizedBox(height: 6),
            Text(
              'This band has no cuff. It reports these numbers from features '
              'of the pulse waveform its optical sensor sees, against a '
              'factory model — not against a cuff reading from your arm. '
              'They are not a blood-pressure measurement, they have not been '
              'calibrated for you, and no medical decision should be made '
              'from them.',
              style: t.textTheme.bodySmall?.copyWith(color: kText, height: 1.4),
            ),
            const SizedBox(height: 8),
            Text(
              'They are kept because the underlying waveform data is real and '
              'may be worth studying. That is a different claim from telling '
              'you your blood pressure.',
              style: t.textTheme.bodySmall?.copyWith(color: kMuted, height: 1.4),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        DotPlot(
          series: [
            DotSeries('systolic', _sys, kBad),
            DotSeries('diastolic', _dia, kAccent),
          ],
          from: now.subtract(const Duration(days: _days)),
          to: now,
        ),
        const SizedBox(height: 6),
        Row(children: [
          _key('systolic', kBad, _sys),
          const SizedBox(width: 16),
          _key('diastolic', kAccent, _dia),
        ]),
        const SizedBox(height: 6),
        // The same grammar every other figure carries: how many readings,
        // over what window, how recently.
        Basis(_sys.isEmpty && _dia.isEmpty
            ? 'nothing recorded in the last $_days days'
            : '${_sys.length} systolic, ${_dia.length} diastolic over '
                '$_days days; last '
                '${DateFormat.MMMd().add_Hm().format(_latest()!)}. '
                'One mark per reading — the gaps are gaps, not a flat line.'),
      ],
    ]);
  }

  DateTime? _latest() {
    final all = [..._sys, ..._dia];
    if (all.isEmpty) return null;
    return all.map((e) => e.at).reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Widget _key(String label, Color c, List<Sample> data) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, color: c),
          const SizedBox(width: 6),
          Text(
            data.isEmpty
                ? label
                : '$label  ${data.last.value.round()}',
            style: TextStyle(fontFamily: kMono, fontSize: 11, color: kMuted),
          ),
        ],
      );
}
