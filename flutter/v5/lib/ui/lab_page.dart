import 'package:flutter/material.dart';

import 'kit.dart';
import 'package:flutter/services.dart';

import '../ble/band_link.dart';
import '../protocol/findings.dart';
import '../protocol/jstyle.dart' as j;
import 'findings_page.dart';

/// Protocol lab — send any opcode and read the raw reply.
///
/// This is the reverse-engineering surface. It exists because the fastest way
/// to settle a protocol question is to ask the band while it is on your wrist,
/// and because the two public implementations of this protocol disagree with
/// each other on several opcodes.
class LabPage extends StatefulWidget {
  const LabPage({super.key});
  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> {
  final link = BandLink.instance;
  final _opCtl = TextEditingController(text: '13');
  final _payloadCtl = TextEditingController();
  String _cs = j.kChecksumSum;
  bool _busy = false;
  List<Reply> _replies = const [];
  String? _error;

  int? get _opcode {
    final t = _opCtl.text.trim().replaceAll('0x', '');
    return int.tryParse(t, radix: 16);
  }

  j.Op? get _knownOp => _opcode == null ? null : j.opsByCode[_opcode!];

  List<int>? get _payload {
    final t = _payloadCtl.text.trim().replaceAll(RegExp(r'[\s,]'), '');
    if (t.isEmpty) return const [];
    if (t.length.isOdd) return null;
    final out = <int>[];
    for (var i = 0; i < t.length; i += 2) {
      final b = int.tryParse(t.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }

  Future<void> _send() async {
    final op = _opcode;
    final payload = _payload;
    setState(() => _error = null);
    if (op == null || op > 0xFF) {
      setState(() => _error = 'Opcode must be one or two hex digits.');
      return;
    }
    if (payload == null) {
      setState(() => _error = 'Payload must be an even number of hex digits.');
      return;
    }
    if (!link.connected) {
      setState(() => _error = 'Not connected — connect on the Band tab first.');
      return;
    }

    final known = j.opsByCode[op];
    if (known != null && known.risk.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('0x${op.toRadixString(16).toUpperCase()} writes to the band'),
          content: Text('${known.name}\n\n${known.risk}\n\n'
              '${known.settled ? "ALREADY SETTLED — ${known.verdict}\n\n" : ""}'
              'This changes device state and may not be reversible. Send it?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(known.settled ? 'Re-run anyway' : 'Send anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      final mark = link.replies.length;
      await link.send(j.frame(op, payload: payload, checksum: _cs),
          wait: const Duration(milliseconds: 900));
      // History transfers keep streaming, so hold the window open while data
      // flows — but BOUND it. 0x78 starts a continuous stream that never goes
      // idle, so an idle-only condition waits forever, and the band keeps
      // streaming (and draining its battery) the whole time.
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      var last = link.replies.length;
      var idle = 0;
      while (idle < 8 && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (link.replies.length != last) {
          last = link.replies.length;
          idle = 0;
        } else {
          idle++;
        }
      }
      setState(() => _replies = link.replies.sublist(mark));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      // Never leave the band streaming. `78 01` has a mandatory partner.
      if (op == j.opStartRawPpg && payload.isNotEmpty && payload.first != 0) {
        try {
          await link.send(j.frame(j.opStartRawPpg,
              payload: const [0x00], checksum: _cs));
        } catch (_) {
          // Best effort: the send already failed or the link dropped.
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final known = _knownOp;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Protocol lab', style: t.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Send a raw frame and read what comes back. Frames are '
          '[opcode][payload…] padded to 16 bytes with a trailing checksum.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Card(
          color: t.colorScheme.surfaceContainerHighest,
          child: ListTile(
            leading: Icon(Icons.menu_book_outlined,
                color: t.colorScheme.tertiary),
            title: const Text('Findings'),
            subtitle: Text(
                '${findings.length} established on hardware · '
                '${corrections.length} correct an earlier belief',
                style: t.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FindingsPage())),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: _opCtl,
              decoration: const InputDecoration(
                  labelText: 'Opcode (hex)',
                  border: OutlineInputBorder(),
                  prefixText: '0x'),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-Fx]'))
              ],
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _payloadCtl,
              decoration: const InputDecoration(
                  labelText: 'Payload (hex, optional)',
                  hintText: '00',
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _cs,
              decoration: const InputDecoration(
                  labelText: 'Checksum', border: OutlineInputBorder()),
              items: [
                for (final k in j.checksums.keys)
                  DropdownMenuItem(value: k, child: Text(k))
              ],
              onChanged: (v) => setState(() => _cs = v ?? j.kChecksumSum),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: const Text('Send'),
          ),
        ]),
        if (_opcode != null) ...[
          const SizedBox(height: 12),
          _framePreview(t),
        ],
        if (known != null) ...[
          const SizedBox(height: 12),
          _opInfo(known, t),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Card(
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style: TextStyle(color: t.colorScheme.onErrorContainer)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text('Known opcodes', style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in j.ops)
            ActionChip(
              avatar: Icon(
                o.safe ? Icons.download : Icons.warning_amber,
                size: 16,
                color: o.safe ? null : t.colorScheme.error,
              ),
              label: Text(
                  '0x${o.code.toRadixString(16).padLeft(2, '0').toUpperCase()} '
                  '${o.name}${o.settled ? '  ✓settled' : ''}'),
              onPressed: () => setState(() {
                _opCtl.text = o.code.toRadixString(16).padLeft(2, '0');
                _payloadCtl.text =
                    o.name.startsWith('hist_') || o.code == j.opGetPpi ? '00' : '';
              }),
            ),
        ]),
        const SizedBox(height: 24),
        if (_replies.isNotEmpty) _replySection(t),
      ],
    );
  }

  Widget _framePreview(ThemeData t) {
    final payload = _payload;
    if (_opcode == null || payload == null) return const SizedBox.shrink();
    try {
      final f = j.frame(_opcode!, payload: payload, checksum: _cs);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Frame to send', style: t.textTheme.labelSmall),
            const SizedBox(height: 4),
            SelectableText(j.hex(f),
                style: const TextStyle(fontFamily: kMono, fontSize: 12)),
          ]),
        ),
      );
    } catch (e) {
      return Text('$e', style: TextStyle(color: t.colorScheme.error));
    }
  }

  Widget _opInfo(j.Op o, ThemeData t) {
    final risky = o.risk.isNotEmpty;
    return Card(
      color: risky ? t.colorScheme.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(risky ? Icons.warning_amber : Icons.info_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${o.name}   (${o.source})',
                    style: t.textTheme.titleSmall)),
          ]),
          if (o.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(o.note, style: t.textTheme.bodySmall),
          ],
          if (risky) ...[
            const SizedBox(height: 6),
            Text(o.risk,
                style: t.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: t.colorScheme.onErrorContainer)),
          ],
          if (o.settled) ...[
            const SizedBox(height: 10),
            _verdictBanner(o, t),
          ],
          ...() {
            // The finding you need is the one about the opcode in your hand.
            final fs = findingsForOpcode(o.code);
            if (fs.isEmpty) return <Widget>[];
            return [
              const SizedBox(height: 10),
              for (final f in fs)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Icon(Icons.label_important_outline,
                        size: 14, color: t.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('${f.status.label} — ${f.title}',
                          style: t.textTheme.bodySmall
                              ?.copyWith(color: t.colorScheme.tertiary)),
                    ),
                  ]),
                ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FindingsPage())),
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text('Open findings'),
              ),
            ];
          }(),
        ]),
      ),
    );
  }

  /// A settled question, shown at the moment it can still save you a probe.
  ///
  /// The point is not decoration: 0x78 looks like exactly the opcode you want
  /// when you are hunting for a pulse, and it costs battery and wrist time to
  /// find out again that it carries none.
  Widget _verdictBanner(j.Op o, ThemeData t) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border(
            left: BorderSide(color: t.colorScheme.tertiary, width: 3)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.gavel, size: 14, color: t.colorScheme.tertiary),
          const SizedBox(width: 6),
          Text('SETTLED — investigated on hardware',
              style: t.textTheme.labelSmall?.copyWith(
                  color: t.colorScheme.tertiary,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        Text(o.verdict, style: t.textTheme.bodySmall),
      ]),
    );
  }

  Widget _replySection(ThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('${_replies.length} reply packet(s)',
              style: t.textTheme.titleSmall),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(
                  text: _replies.map((r) => r.hex).join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied hex to clipboard')));
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
        ]),
        const SizedBox(height: 8),
        for (var i = 0; i < _replies.length; i++) _replyTile(i, _replies[i], t),
      ],
    );
  }

  Widget _replyTile(int i, Reply r, ThemeData t) {
    final hint = j.summariseRecord(r.data);
    final op = j.opsByCode[r.opcode];
    final settledOp = (op != null && op.settled) ? op : null;
    final cs = j.whichChecksum(r.data);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('[$i]  0x'
                '${r.opcode.toRadixString(16).padLeft(2, '0').toUpperCase()} '
                '${j.opName(r.opcode)}',
                style: t.textTheme.labelMedium),
            const Spacer(),
            Text('${r.data.length} B', style: t.textTheme.labelSmall),
          ]),
          const SizedBox(height: 6),
          SelectableText(r.hex,
              style: const TextStyle(fontFamily: kMono, fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            if (r.isResponse)
              const Chip(
                  label: Text('response bit', style: TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact),
            if (cs.isNotEmpty)
              Chip(
                  label: Text('cs: ${cs.join(", ")}',
                      style: const TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact),
            if (r.isEmpty)
              const Chip(
                  label: Text('empty', style: TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact),
          ]),
          // A settled-negative opcode must not be annotated with
          // heart-rate heuristics. summariseRecord happily labels 0x3A
          // frames "HR-bytes@0..202", which is exactly the false lead the
          // verdict exists to close off.
          if (settledOp != null) ...[
            const SizedBox(height: 4),
            Text('settled: no pulse in this stream — see the verdict above',
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.tertiary)),
          ] else if (hint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(hint,
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.primary)),
          ],
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _opCtl.dispose();
    _payloadCtl.dispose();
    super.dispose();
  }
}
