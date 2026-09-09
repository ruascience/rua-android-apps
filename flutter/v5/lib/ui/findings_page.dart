import 'package:flutter/material.dart';

import '../protocol/findings.dart';

/// What we know about this band, browsable.
///
/// The Lab answers "what does opcode X do?" — but only if you already know to
/// ask about X. This page answers the question you actually have when holding
/// an unfamiliar band: what has been established, what was wrong, and what is
/// still open.
class FindingsPage extends StatefulWidget {
  const FindingsPage({super.key});
  @override
  State<FindingsPage> createState() => _FindingsPageState();
}

class _FindingsPageState extends State<FindingsPage> {
  FindingArea? _area;
  bool _correctionsOnly = false;

  List<Finding> get _visible => [
        for (final f in findings)
          if ((_area == null || f.area == _area) &&
              (!_correctionsOnly || f.correctsSomething))
            f
      ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final visible = _visible;
    final open = findings.where((f) => f.status == FindingStatus.open).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Findings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('What we know about the V5', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '${findings.length} entries · ${provisional.length} not yet '
            'verified on a V5 · $open still open.',
            style: t.textTheme.bodySmall,
          ),
          if (nothingConfirmedOnV5) ...[
            const SizedBox(height: 12),
            _standingCaveat(t),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilterChip(
              label: const Text('All'),
              selected: _area == null && !_correctionsOnly,
              onSelected: (_) => setState(() {
                _area = null;
                _correctionsOnly = false;
              }),
            ),
            FilterChip(
              label: const Text('Corrections'),
              avatar: const Icon(Icons.change_circle_outlined, size: 16),
              selected: _correctionsOnly,
              onSelected: (v) => setState(() {
                _correctionsOnly = v;
                if (v) _area = null;
              }),
            ),
            for (final a in FindingArea.values)
              FilterChip(
                label: Text(a.label),
                selected: _area == a,
                onSelected: (v) => setState(() {
                  _area = v ? a : null;
                  if (v) _correctionsOnly = false;
                }),
              ),
          ]),
          const SizedBox(height: 16),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text('Nothing matches that filter.',
                  style: t.textTheme.bodyMedium),
            )
          else
            for (final f in visible) ...[
              _card(f, t),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }

  /// The whole app hangs on this distinction being visible at a glance:
  /// measured on THIS band, versus inherited from another one.
  Color _statusColour(FindingStatus s, ThemeData t) => switch (s) {
        FindingStatus.confirmed => t.colorScheme.primary,
        FindingStatus.assumed => t.colorScheme.error,
        FindingStatus.closed => t.colorScheme.tertiary,
        FindingStatus.refuted => t.colorScheme.error,
        FindingStatus.open => t.colorScheme.outline,
      };

  IconData _statusIcon(FindingStatus s) => switch (s) {
        FindingStatus.confirmed => Icons.verified_outlined,
        FindingStatus.assumed => Icons.science_outlined,
        FindingStatus.closed => Icons.gavel,
        FindingStatus.refuted => Icons.cancel_outlined,
        FindingStatus.open => Icons.help_outline,
      };

  /// Shown while no finding has been confirmed on a V5.
  ///
  /// Without this the app looks like it knows things about this band that it
  /// does not. Inherited numbers decode into plausible values rather than
  /// obvious failures, which is exactly why the caveat has to be standing
  /// rather than buried.
  Widget _standingCaveat(ThemeData t) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: t.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.warning_amber,
                size: 16, color: t.colorScheme.onErrorContainer),
            const SizedBox(width: 6),
            Text('Nothing is confirmed on a V5 yet',
                style: t.textTheme.labelLarge?.copyWith(
                    color: t.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          Text(
            'The V5 has no public SDK, protocol doc or GATT dump. This app '
            'carries the protocol measured on a JCVital Pro V8 as a working '
            'hypothesis. A band that answers the same opcodes is not thereby '
            'proven to use the same record layouts — and a wrong offset '
            'produces believable numbers, not errors. Verify before trusting '
            'anything here.',
            style: t.textTheme.bodySmall
                ?.copyWith(color: t.colorScheme.onErrorContainer),
          ),
        ]),
      );

  Widget _card(Finding f, ThemeData t) {
    final colour = _statusColour(f.status, t);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_statusIcon(f.status), size: 16, color: colour),
            const SizedBox(width: 8),
            Expanded(
              child: Text(f.title,
                  style: t.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            Chip(
              label: Text(f.status.label,
                  style: TextStyle(fontSize: 10, color: colour)),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: colour.withValues(alpha: 0.5)),
            ),
            Chip(
              label: Text(f.area.label, style: const TextStyle(fontSize: 10)),
              visualDensity: VisualDensity.compact,
            ),
            for (final op in f.opcodes)
              Chip(
                label: Text(
                    '0x${op.toRadixString(16).padLeft(2, '0').toUpperCase()}',
                    style: const TextStyle(fontSize: 10)),
                visualDensity: VisualDensity.compact,
              ),
          ]),
          const SizedBox(height: 10),
          Text(f.summary, style: t.textTheme.bodyMedium),
          const SizedBox(height: 10),
          _labelled('How we know (${f.provenance.label})', f.evidence, t,
              f.isProvisional ? t.colorScheme.error : t.colorScheme.outline),
          if (f.howToVerify.isNotEmpty) ...[
            const SizedBox(height: 10),
            _labelled('To verify on a V5', f.howToVerify, t,
                t.colorScheme.tertiary),
          ],
          if (f.correctsSomething) ...[
            const SizedBox(height: 10),
            _labelled('This corrected', f.supersedes, t, t.colorScheme.error),
          ],
        ]),
      ),
    );
  }

  Widget _labelled(String label, String body, ThemeData t, Color colour) =>
      Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: colour, width: 3)),
          color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: t.textTheme.labelSmall
                  ?.copyWith(color: colour, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(body, style: t.textTheme.bodySmall),
        ]),
      );
}
