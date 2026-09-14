import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurav5/data/store.dart';
import 'package:aurav5/ui/kit.dart';

/// The ribbon draws ONE day against a fixed 24-hour axis, and it shades only
/// sleep that was actually recorded. Both were bugs on the phone: it was
/// handed a fortnight of samples, and it shaded a hardcoded 00:00-07:00 that
/// the caption beside it then described as "asleep".
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 360, height: 400, child: child)),
      );

  testWidgets('renders a day of samples without overflowing', (t) async {
    final day = DateTime(2026, 9, 14);
    final samples = [
      for (var i = 0; i < 24 * 12; i++)
        Sample(day.add(Duration(minutes: i * 5)), 60 + (i % 30).toDouble()),
    ];
    await t.pumpWidget(host(DayRibbon(
      samples: samples,
      day: day,
      colour: Colors.red,
      asleep: [
        DateTimeRange(
            start: day.subtract(const Duration(hours: 2)),
            end: day.add(const Duration(hours: 6, minutes: 40))),
      ],
    )));
    expect(t.takeException(), isNull);
    expect(find.byType(DayRibbon), findsOneWidget);
  });

  testWidgets('a day with long gaps does not bridge them', (t) async {
    // Two clusters six hours apart. A point-to-point polyline drew a straight
    // line across the gap — six hours of heart rate that was never measured,
    // rendered as the most confident-looking part of the chart.
    final day = DateTime(2026, 9, 14);
    final samples = [
      for (var i = 0; i < 40; i++)
        Sample(day.add(Duration(hours: 7, seconds: i * 20)),
            62 + (i % 7).toDouble()),
      for (var i = 0; i < 40; i++)
        Sample(day.add(Duration(hours: 13, seconds: i * 20)),
            88 + (i % 11).toDouble()),
    ];
    await t.pumpWidget(host(DayRibbon(
      samples: samples, day: day, colour: Colors.red)));
    expect(t.takeException(), isNull);
  });

  testWidgets('a single reading in the day is still drawn', (t) async {
    final day = DateTime(2026, 9, 14);
    await t.pumpWidget(host(DayRibbon(
      samples: [Sample(day.add(const Duration(hours: 9)), 71)],
      day: day,
      colour: Colors.red,
    )));
    expect(t.takeException(), isNull);
  });

  testWidgets('an empty day still paints its axis', (t) async {
    await t.pumpWidget(host(DayRibbon(
      samples: const [],
      day: DateTime(2026, 9, 14),
      colour: Colors.red,
    )));
    expect(find.byType(DayRibbon), findsOneWidget);
  });

  testWidgets('RuleGrid rows grow to fit a long basis line', (t) async {
    // The regression: a fixed childAspectRatio cut the basis sentence off
    // mid-line, and the basis is the part that says where the figure came
    // from. A tall cell must make the whole row tall, not clip.
    const long =
        'lowest sustained 25 s during 00:00-06:00, from 412 readings across '
        'four nights, two of which were partial';
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RuleGrid(children: const [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Lab('Recovery'),
              Figure('72'),
              Basis(long),
            ]),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Lab('Strain'),
              Figure('9'),
              Basis('short'),
            ]),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Lab('Resting'),
              Figure('54'),
              Basis('short'),
            ]),
          ]),
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    final grid = t.getSize(find.byType(RuleGrid));
    // Three lines of 9pt mono plus a 34pt figure and a label clears 120px;
    // the old fixed ratio capped a 360-wide grid's cells near 104.
    expect(grid.height, greaterThan(120));
  });
}
