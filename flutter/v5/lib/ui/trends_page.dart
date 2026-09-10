import 'package:flutter/material.dart';

import 'history_page.dart';
import 'insights_page.dart';
import 'kit.dart';

/// Trends — one tab for both questions about the long run.
///
/// This was two destinations, Insights and History, and answering a single
/// question meant flipping between them: History said what resting heart rate
/// has been doing, Insights said what it adds up to, and neither was readable
/// without the other. They are one scroll now, in that order — the series
/// first, because a figure derived from it means nothing until you have seen
/// the shape it came from.
class TrendsPage extends StatelessWidget {
  const TrendsPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          const HistorySection(),
          const SizedBox(height: 24),
          Divider(height: 1, color: kRule),
          const SizedBox(height: 20),
          const InsightsSection(),
        ],
      );
}
