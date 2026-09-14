import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurav5/data/store.dart';
import 'package:aurav5/ui/kit.dart';

/// Spot signals are marks, not lines — the whole point of the widget is that
/// four readings across a fortnight do not become a trend.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 360, height: 300, child: child)),
      );

  final to = DateTime(2026, 9, 14, 12);
  final from = to.subtract(const Duration(days: 14));

  testWidgets('draws two series of spot readings', (t) async {
    await t.pumpWidget(host(DotPlot(
      from: from,
      to: to,
      series: [
        DotSeries('systolic', [
          for (var i = 0; i < 9; i++)
            Sample(from.add(Duration(days: i, hours: 3)), 118 + i.toDouble()),
        ], Colors.red),
        DotSeries('diastolic', [
          for (var i = 0; i < 9; i++)
            Sample(from.add(Duration(days: i, hours: 3)), 74 + i.toDouble()),
        ], Colors.blue),
      ],
    )));
    expect(t.takeException(), isNull);
    expect(find.text('no readings in this window'), findsNothing);
  });

  testWidgets('says so rather than drawing an empty axis', (t) async {
    await t.pumpWidget(host(DotPlot(
      from: from,
      to: to,
      series: const [DotSeries('systolic', [], Colors.red)],
    )));
    expect(find.text('no readings in this window'), findsOneWidget);
  });

  testWidgets('a single reading does not become a range band', (t) async {
    // Two readings cannot establish a personal range; shading one anyway
    // would present a band the data does not support.
    await t.pumpWidget(host(DotPlot(
      from: from,
      to: to,
      series: [
        DotSeries('systolic', [Sample(to, 121)], Colors.red),
      ],
    )));
    expect(t.takeException(), isNull);
  });
}
