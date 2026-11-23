import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../widgets/prompt.dart';
import '../modbus_controller.dart';
import '../modbus_models.dart';
import '../presets.dart';
import '../protocol/modbus_codec.dart';
import '../protocol/value_format.dart';
import 'form_rows.dart';
import 'sheets.dart';

/// The live register table: one block per poll. Tap a row to chart it;
/// the pencil writes a register, the switch toggles a coil.
class RegistersView extends ConsumerWidget {
  const RegistersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modbusProvider);
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    if (s.polls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Add a poll to see registers.\nSetup › Add Poll, or pick one from the Library.',
            textAlign: TextAlign.center,
            style: AppText.subheadline.copyWith(color: secondary),
          ),
        ),
      );
    }
    final rows = <Widget>[];
    for (final p in s.polls) {
      rows.add(_PollHeader(poll: p));
      final step = p.def.isBits ? 1 : s.config.format.registers;
      for (var i = 0; i < p.def.quantity; i += step) {
        rows.add(_RegisterRow(poll: p, index: i, format: s.config.format, selected: s.trendKey == (p.def.id, i)));
      }
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: rows);
  }
}

class _PollHeader extends StatelessWidget {
  const _PollHeader({required this.poll});

  final PollState poll;

  @override
  Widget build(BuildContext context) {
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final t = poll.lastAt;
    return Container(
      color: context.resolve(CupertinoColors.systemGroupedBackground),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(poll.def.name, style: AppText.headline),
                Text(
                  poll.error ?? '${poll.def.summary}${t == null ? '' : ' · ${_time(t)}'}',
                  style: AppText.footnote.copyWith(
                    color: poll.error != null ? context.resolve(CupertinoColors.systemRed) : secondary,
                  ),
                ),
              ],
            ),
          ),
          Text('${poll.reads}', style: AppText.footnote.copyWith(color: secondary)),
        ],
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _RegisterRow extends ConsumerWidget {
  const _RegisterRow({required this.poll, required this.index, required this.format, required this.selected});

  final PollState poll;
  final int index;
  final ValueFormat format;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modbus = ref.read(modbusProvider.notifier);
    final address = poll.def.address + index;
    final has = index < poll.values.length;
    final bits = poll.def.isBits;
    final value = has ? formatValue(poll.values, index, format, bits: bits) : '-';
    final raw = has && !bits ? hex16(poll.values[index]) : '';
    final changed = poll.changed.contains(index) || (format.registers == 2 && poll.changed.contains(index + 1));
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final writable = poll.def.func == Fc.readHoldingRegisters || poll.def.func == Fc.readCoils;
    final connected = ref.watch(modbusProvider.select((s) => s.connected));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        modbus.selectTrend(poll.def.id, index);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        color: context.resolve(
          selected
              ? CupertinoColors.systemBlue.withValues(alpha: 0.12)
              : changed
              ? CupertinoColors.systemYellow.withValues(alpha: 0.18)
              : CupertinoColors.secondarySystemGroupedBackground,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text('$address', style: monoStyle.copyWith(color: secondary)),
            ),
            Expanded(
              child: Text(value, style: monoStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (raw.isNotEmpty && format != ValueFormat.hex)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(raw, style: monoStyle.copyWith(fontSize: 12, color: secondary)),
              ),
            if (writable && bits)
              CupertinoSwitch(
                value: has && poll.values[index] != 0,
                onChanged: connected
                    ? (v) => _run(context, () => modbus.write(Fc.writeSingleCoil, address, [v ? 1 : 0]))
                    : null,
              )
            else if (writable)
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(32, 32),
                onPressed: connected ? () => _writeRegister(context, ref, address) : null,
                child: const Icon(CupertinoIcons.pencil, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _writeRegister(BuildContext context, WidgetRef ref, int address) async {
    if (format.registers == 2) {
      return showWriteSheet(context, func: Fc.writeMultipleRegisters, address: address);
    }
    final current = index < poll.values.length ? '${poll.values[index]}' : '';
    final text = await showTextPrompt(
      context,
      title: 'Write Register $address',
      message: 'FC 06 · decimal or 0x hex',
      initialValue: current,
      confirmLabel: 'Write',
    );
    final v = text == null ? null : parseInt(text);
    if (v == null || !context.mounted) return;
    await _run(context, () => ref.read(modbusProvider.notifier).write(Fc.writeSingleRegister, address, [v]));
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (context.mounted) showAlert(context, 'Write Failed', '$e');
    }
  }
}

/// Trend of the selected register.
class TrendView extends ConsumerWidget {
  const TrendView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modbusProvider);
    final key = s.trendKey;
    final poll = key == null ? null : s.polls.where((p) => p.def.id == key.$1).firstOrNull;
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    if (poll == null) {
      return Center(
        child: Text('Add a poll, then tap a register to chart it.', style: TextStyle(color: secondary)),
      );
    }
    final last = s.trend.lastOrNull;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${poll.def.name} · Address ${poll.def.address + key!.$2}', style: AppText.headline),
          Text(
            last == null
                ? 'Waiting for readings… Tap any register in Registers to chart it.'
                : 'Now ${_num(last)} · min ${_num(s.trend.reduce(min))} · max ${_num(s.trend.reduce(max))} · ${s.trend.length} samples',
            style: AppText.footnote.copyWith(color: secondary),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.resolve(CupertinoColors.secondarySystemGroupedBackground),
                borderRadius: BorderRadius.circular(12),
              ),
              child: CustomPaint(
                painter: _TrendPainter(
                  s.trend,
                  line: context.resolve(CupertinoColors.systemBlue),
                  grid: context.resolve(CupertinoColors.separator),
                  label: secondary,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(3);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.values, {required this.line, required this.grid, required this.label});

  final List<double> values;
  final Color line, grid, label;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = EdgeInsets.fromLTRB(52, 12, 12, 12);
    final area = pad.deflateRect(Offset.zero & size);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    if (values.length < 2) return;
    var lo = values.reduce(min), hi = values.reduce(max);
    if (hi == lo) {
      hi += 1;
      lo -= 1;
    }
    final span = hi - lo;
    for (var i = 0; i <= 4; i++) {
      final y = area.bottom - area.height * i / 4;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: TrendView._num(lo + span * i / 4),
          style: TextStyle(color: label, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: pad.left - 6);
      tp.paint(canvas, Offset(pad.left - 6 - tp.width, y - tp.height / 2));
    }
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = area.left + area.width * i / (values.length - 1);
      final y = area.bottom - area.height * (values[i] - lo) / span;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.values != values || old.line != line;
}

/// TX/RX traffic and events, newest at the bottom.
class LogView extends ConsumerWidget {
  const LogView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(modbusLogProvider);
    final stats = ref.watch(modbusProvider.select((s) => s.stats));
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    Color colorOf(LogKind k) => context.resolve(switch (k) {
      LogKind.tx => CupertinoColors.systemBlue,
      LogKind.rx => CupertinoColors.systemGreen,
      LogKind.error => CupertinoColors.systemRed,
      LogKind.info => CupertinoColors.label,
    });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Requests ${stats.requests} · Errors ${stats.errors} · Last ${stats.lastMs} ms',
                  style: AppText.footnote.copyWith(color: secondary),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: log.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(
                          text: log.map((e) => '[${e.at.toIso8601String()}] ${e.tag}: ${e.text}').join('\n'),
                        ),
                      ),
                child: const Text('Copy'),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: log.isEmpty ? null : ref.read(modbusLogProvider.notifier).clear,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: log.isEmpty
              ? Center(
                  child: Text('No traffic yet.', style: TextStyle(color: secondary)),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: log.length,
                  itemBuilder: (context, i) {
                    final e = log[log.length - 1 - i];
                    final t = e.at.toIso8601String().substring(11, 23);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$t ',
                              style: TextStyle(color: secondary),
                            ),
                            TextSpan(
                              text: '${e.tag.padRight(3)} ',
                              style: TextStyle(color: colorOf(e.kind), fontWeight: FontWeight.w700),
                            ),
                            TextSpan(
                              text: e.text,
                              style: TextStyle(color: colorOf(e.kind)),
                            ),
                          ],
                        ),
                        style: monoStyle.copyWith(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// The register library: search, filter by category, add as a poll.
class LibraryView extends ConsumerStatefulWidget {
  const LibraryView({super.key});

  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView> {
  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(modbusProvider);
    final presets = s.presets;
    final categories = {for (final p in presets) p.category}.toList();
    final shown = [
      for (final p in presets)
        if ((_category == null || p.category == _category) && p.matches(_query)) p,
    ];
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final blue = context.resolve(CupertinoColors.systemBlue);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: CupertinoSearchTextField(
            placeholder: 'Name, address or description',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () async {
                  final picked = await pickOption<String>(
                    context,
                    title: 'Category',
                    options: ['', ...categories],
                    labelOf: (c) => c.isEmpty ? 'All Categories' : _label(c),
                    current: _category ?? '',
                  );
                  if (picked != null) setState(() => _category = picked.isEmpty ? null : picked);
                },
                child: Text(_category == null ? 'All Categories' : _label(_category!)),
              ),
              const Spacer(),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () => showImportPresetsSheet(context),
                child: const Text('Import…'),
              ),
              if (s.customPresets.isNotEmpty)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: ref.read(modbusProvider.notifier).clearCustomPresets,
                  child: Text('Remove Imported', style: TextStyle(color: context.resolve(CupertinoColors.systemRed))),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final p = shown[i];
              return CupertinoListTile(
                title: Text(p.name),
                subtitle: Text(
                  [
                    'FC0${p.func} · ${p.address}${p.count > 1 ? ' ×${p.count}' : ''}',
                    if (p.unit.isNotEmpty) p.unit,
                    if (p.description.isNotEmpty) p.description,
                  ].join(' · '),
                  maxLines: 2,
                  style: TextStyle(color: secondary),
                ),
                trailing: CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  onPressed: () => _add(p),
                  child: Icon(CupertinoIcons.add_circled_solid, color: blue),
                ),
                onTap: () => _add(p),
              );
            },
          ),
        ),
      ],
    );
  }

  void _add(RegisterPreset p) {
    ref.read(modbusProvider.notifier).addPreset(p);
    HapticFeedback.selectionClick();
    showAlert(context, 'Poll Added', '“${p.name}” (address ${p.address}) was added to your polls.');
  }

  static String _label(String c) =>
      c.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}
