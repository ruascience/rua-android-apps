import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ble/band_link.dart';
import '../data/store.dart';

const _metrics = ['heart_rate', 'temperature', 'spo2', 'hrv', 'stress'];

const _labels = {
  'heart_rate': 'Heart rate (bpm)',
  'temperature': 'Skin temperature (°C)',
  'spo2': 'Blood oxygen (%)',
  'hrv': 'HRV (ms)',
  'stress': 'Stress',
};

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _metric = 'heart_rate';
  int _days = 7;
  List<Sample> _data = const [];
  bool _loading = false;
  bool _truncated = false;

  /// This page had no listeners at all: IndexedStack mounts it at startup with
  /// no band connected, so it loaded nothing and then never reloaded. After a
  /// successful sync it still read "No heart rate data yet" until the user
  /// happened to tap a chip.
  String _loadedFor = '';
  int _loadedRevision = -1;
  StreamSubscription<void>? _linkSub;
  StreamSubscription<int>? _dataSub;

  @override
  void initState() {
    super.initState();
    _load();
    _linkSub = BandLink.instance.changes.listen((_) {
      final dev = BandLink.instance.deviceName;
      if (dev.isNotEmpty && dev != _loadedFor && !_loading) _load();
    });
    _dataSub = Store.instance.changes.listen((rev) {
      if (rev != _loadedRevision && !_loading) _load();
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _dataSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final dev = BandLink.instance.deviceName;
    // Do NOT clear existing data on disconnect — replacing a real chart with
    // a "no data" placeholder is worse than showing the last known series.
    if (dev.isEmpty) return;
    setState(() => _loading = true);
    final since = DateTime.now().subtract(Duration(days: _days));
    final d = await Store.instance.read(dev, _metric, since: since);
    final cut =
        await Store.instance.wasTruncated(dev, _metric, since: since);
    if (mounted) {
      setState(() {
        _data = d;
        _truncated = cut;
        _loading = false;
        _loadedFor = dev;
        _loadedRevision = Store.instance.revision;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // No heading: the tab above this page says History.
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final m in _metrics)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(_labels[m]!.split(' (').first),
                  selected: _metric == m,
                  onSelected: (_) {
                    setState(() => _metric = m);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Row(children: [
          for (final d in [1, 7, 30])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(d == 1 ? '24 h' : '$d d'),
                selected: _days == d,
                onSelected: (_) {
                  setState(() => _days = d);
                  _load();
                },
              ),
            ),
          const Spacer(),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 16),
        if (_loading)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator()))
        else if (_data.isEmpty)
          _empty(t)
        else ...[
          _stats(t),
          const SizedBox(height: 16),
          SizedBox(height: 260, child: _chart(t)),
        ],
      ],
    );
  }

  Widget _empty(ThemeData t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(children: [
          Icon(Icons.show_chart, size: 40, color: t.disabledColor),
          const SizedBox(height: 12),
          Text('No ${_labels[_metric]!.split(' (').first.toLowerCase()} data yet',
              style: t.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('Connect on the Band tab and press Sync history.',
              style: t.textTheme.bodySmall, textAlign: TextAlign.center),
        ]),
      );

  Widget _stats(ThemeData t) {
    final vals = _data.map((s) => s.value).toList()..sort();
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final median = vals[vals.length ~/ 2];
    String f(double v) =>
        _metric == 'temperature' ? v.toStringAsFixed(2) : v.round().toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          // Say so when the window holds more than we read, rather than
          // printing the returned count as if it were the true total.
          _stat(_truncated ? 'newest' : 'samples', '${vals.length}', t),
          _stat('min', f(vals.first), t),
          _stat('median', f(median), t),
          _stat('mean', f(mean), t),
          _stat('max', f(vals.last), t),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, ThemeData t) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: t.textTheme.titleMedium),
          Text(label, style: t.textTheme.labelSmall),
        ],
      );

  Widget _chart(ThemeData t) {
    final spots = [
      for (final s in _data)
        FlSpot(s.at.millisecondsSinceEpoch.toDouble(), s.value)
    ];
    final xs = spots.map((s) => s.x);
    final ys = spots.map((s) => s.y);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = ((maxY - minY).abs() * 0.1).clamp(0.5, 20.0);
    final span = xs.last - xs.first;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, meta) => Text(
                _metric == 'temperature'
                    ? v.toStringAsFixed(1)
                    : v.round().toString(),
                style: t.textTheme.labelSmall,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: span <= 0 ? null : span / 3,
              getTitlesWidget: (v, meta) {
                final d =
                    DateTime.fromMillisecondsSinceEpoch(v.toInt());
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _days <= 1
                        ? DateFormat.Hm().format(d)
                        : DateFormat.Md().format(d),
                    style: t.textTheme.labelSmall,
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            barWidth: 2,
            color: t.colorScheme.primary,
            // Individual dots turn a dense overnight series into mud.
            dotData: FlDotData(show: spots.length < 60),
            belowBarData: BarAreaData(
              show: true,
              color: t.colorScheme.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}
