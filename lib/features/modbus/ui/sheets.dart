import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../widgets/adaptive_sheet.dart';
import '../../../widgets/section.dart';
import '../modbus_controller.dart';
import '../modbus_models.dart';
import '../protocol/modbus_codec.dart';
import 'form_rows.dart';

/// Add or edit a poll definition.
Future<void> showPollEditor(BuildContext context, {PollDef? poll}) => showAdaptiveSheet<void>(
  context,
  builder: (context, controller) => _PollEditor(poll: poll, scrollController: controller),
);

class _PollEditor extends ConsumerStatefulWidget {
  const _PollEditor({this.poll, required this.scrollController});

  final PollDef? poll;
  final ScrollController scrollController;

  @override
  ConsumerState<_PollEditor> createState() => _PollEditorState();
}

class _PollEditorState extends ConsumerState<_PollEditor> {
  late PollDef _def = widget.poll ?? ref.read(modbusProvider.notifier).newPoll();

  String? get _problem {
    final maxQty = Fc.isBitRead(_def.func) ? 2000 : 125;
    if (_def.address < 0 || _def.address > 65535) return 'Address must be 0–65535.';
    if (_def.quantity < 1 || _def.quantity > maxQty) return 'Quantity must be 1–$maxQty for this function.';
    if (_def.intervalMs < 50) return 'Scan rate must be at least 50 ms.';
    return null;
  }

  void _save() {
    final problem = _problem;
    if (problem != null) return showAlert(context, 'Check the Poll', problem);
    ref
        .read(modbusProvider.notifier)
        .savePoll(_def.copyWith(name: _def.name.trim().isEmpty ? 'Poll' : _def.name.trim()));
    HapticFeedback.selectionClick();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.poll == null;
    return CupertinoPageScaffold(
      navigationBar: sheetBar(
        context,
        title: isNew ? 'New Poll' : 'Edit Poll',
        action: isNew ? 'Add' : 'Save',
        onAction: _save,
      ),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Section(
            children: [
              TextRow(
                label: 'Name',
                value: _def.name,
                onChanged: (v) => _def = _def.copyWith(name: v),
                width: 200,
              ),
              PickerRow<int>(
                label: 'Function',
                value: _def.func,
                options: Fc.readNames.keys.toList(),
                labelOf: (f) => Fc.readNames[f]!,
                onChanged: (f) => setState(() => _def = _def.copyWith(func: f)),
              ),
            ],
          ),
          Section(
            footer:
                'Address as the device documents it; the address offset in Connection is added on the wire. '
                'Up to ${Fc.isBitRead(_def.func) ? 2000 : 125} ${Fc.isBitRead(_def.func) ? 'bits' : 'registers'} per poll.',
            children: [
              TextRow(
                label: 'Start Address',
                value: '${_def.address}',
                numeric: true,
                onChanged: (v) => _def = _def.copyWith(address: int.tryParse(v) ?? 0),
              ),
              TextRow(
                label: 'Quantity',
                value: '${_def.quantity}',
                numeric: true,
                onChanged: (v) => _def = _def.copyWith(quantity: int.tryParse(v) ?? 0),
              ),
              TextRow(
                label: 'Scan Rate (ms)',
                value: '${_def.intervalMs}',
                numeric: true,
                onChanged: (v) => _def = _def.copyWith(intervalMs: int.tryParse(v) ?? 0),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// FC 05/06/15/16 write.
Future<void> showWriteSheet(BuildContext context, {int func = Fc.writeSingleRegister, int? address, String? values}) =>
    showAdaptiveSheet<void>(
      context,
      builder: (context, controller) =>
          _WriteSheet(func: func, address: address, values: values, scrollController: controller),
    );

class _WriteSheet extends ConsumerStatefulWidget {
  const _WriteSheet({required this.func, this.address, this.values, required this.scrollController});

  final int func;
  final int? address;
  final String? values;
  final ScrollController scrollController;

  @override
  ConsumerState<_WriteSheet> createState() => _WriteSheetState();
}

class _WriteSheetState extends ConsumerState<_WriteSheet> {
  late int _func = widget.func;
  late String _address = '${widget.address ?? 0}';
  late String _values = widget.values ?? '';
  bool _busy = false;

  bool get _multi => _func == Fc.writeMultipleCoils || _func == Fc.writeMultipleRegisters;
  bool get _coils => _func == Fc.writeSingleCoil || _func == Fc.writeMultipleCoils;

  Future<void> _send() async {
    final address = int.tryParse(_address);
    final values = [for (final s in _values.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) parseInt(s)];
    if (address == null || values.isEmpty || values.contains(null)) {
      return showAlert(
        context,
        'Check the Values',
        'Enter an address and ${_multi ? 'values separated by commas' : 'a value'} (decimal or 0x hex).',
      );
    }
    setState(() => _busy = true);
    try {
      await ref.read(modbusProvider.notifier).write(_func, address, [for (final v in values) v!]);
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAlert(context, 'Write Failed', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: sheetBar(context, title: 'Write', action: 'Send', onAction: _send, busy: _busy),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Section(
            footer: _coils
                ? 'Coils: 1 = ON, 0 = OFF.${_multi ? ' Separate values with commas.' : ''}'
                : 'Decimal (-32768–65535) or hex like 0x1F.${_multi ? ' Separate values with commas.' : ''}',
            children: [
              PickerRow<int>(
                label: 'Function',
                value: _func,
                options: Fc.writeNames.keys.toList(),
                labelOf: (f) => Fc.writeNames[f]!,
                onChanged: (f) => setState(() => _func = f),
              ),
              TextRow(label: 'Address', value: _address, numeric: true, onChanged: (v) => _address = v),
              TextRow(
                label: _multi ? 'Values' : 'Value',
                value: _values,
                placeholder: _multi ? '10, 20, 0x1F' : '0',
                monospace: true,
                width: 200,
                onChanged: (v) => _values = v,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Raw PDU: any function code + data bytes, shows the answer.
Future<void> showRawSheet(BuildContext context) =>
    showAdaptiveSheet<void>(context, builder: (context, controller) => _RawSheet(scrollController: controller));

class _RawSheet extends ConsumerStatefulWidget {
  const _RawSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  ConsumerState<_RawSheet> createState() => _RawSheetState();
}

class _RawSheetState extends ConsumerState<_RawSheet> {
  String _func = '0x03';
  String _data = '00 00 00 0A';
  String? _answer;
  bool _error = false;
  bool _busy = false;

  Future<void> _send() async {
    final fc = parseInt(_func);
    if (fc == null || fc < 1 || fc > 127) {
      return showAlert(context, 'Check the Function', 'Use 1–127, decimal or 0x hex.');
    }
    setState(() => _busy = true);
    try {
      final resp = await ref.read(modbusProvider.notifier).sendRaw(fc, parseHexBytes(_data));
      setState(() {
        _error = resp.isNotEmpty && resp[0] & 0x80 != 0;
        _answer = _error
            ? '${toHex(resp)}\n${ModbusException(resp[0] & 0x7F, resp.length > 1 ? resp[1] : 0)}'
            : toHex(resp);
      });
    } catch (e) {
      setState(() {
        _error = true;
        _answer = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = ref.watch(modbusProvider.select((s) => s.config.unitId));
    return CupertinoPageScaffold(
      navigationBar: sheetBar(context, title: 'Send Message', action: 'Send', onAction: _send, busy: _busy),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Section(
            footer: 'Sent to unit $unit. The unit id and MBAP header (TCP) or CRC (RTU) are added for you.',
            children: [
              TextRow(label: 'Function', value: _func, monospace: true, onChanged: (v) => _func = v),
              TextRow(label: 'Data (hex)', value: _data, monospace: true, width: 220, onChanged: (v) => _data = v),
            ],
          ),
          if (_answer != null)
            Section(
              header: 'Response PDU',
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: SelectableText(
                    _answer!,
                    style: monoStyle.copyWith(
                      color: context.resolve(_error ? CupertinoColors.systemRed : CupertinoColors.label),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Unit id scanner.
Future<void> showScannerSheet(BuildContext context) =>
    showAdaptiveSheet<void>(context, builder: (context, controller) => _ScannerSheet(scrollController: controller));

class _ScannerSheet extends ConsumerStatefulWidget {
  const _ScannerSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  ConsumerState<_ScannerSheet> createState() => _ScannerSheetState();
}

class _ScannerSheetState extends ConsumerState<_ScannerSheet> {
  String _from = '1';
  String _to = '10';
  int _func = Fc.readHoldingRegisters;
  String _address = '0';
  final _results = <({int unit, String result, bool found})>[];
  StreamSubscription<({int unit, String result, bool found})>? _sub;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    final from = int.tryParse(_from) ?? 1, to = int.tryParse(_to) ?? 247;
    if (from < 0 || to > 247 || from > to) return showAlert(context, 'Check the Range', 'Unit ids go from 0 to 247.');
    setState(_results.clear);
    _sub = ref
        .read(modbusProvider.notifier)
        .scan(from: from, to: to, fc: _func, address: int.tryParse(_address) ?? 0)
        .listen((r) => setState(() => _results.add(r)), onDone: () => setState(() => _sub = null));
  }

  void _stop() {
    ref.read(modbusProvider.notifier).cancelScan();
    _sub?.cancel();
    _sub = null;
  }

  @override
  Widget build(BuildContext context) {
    final scanning = _sub != null;
    final found = _results.where((r) => r.found).length;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        middle: const Text('Device Scanner'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: scanning ? () => setState(_stop) : _start,
          child: Text(scanning ? 'Stop' : 'Scan', style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Section(
            footer:
                'Asks each unit id for one register. Devices that answer — even with an exception — are found. '
                'Each silent id waits for the full timeout.',
            children: [
              TextRow(label: 'From Unit', value: _from, numeric: true, onChanged: (v) => _from = v),
              TextRow(label: 'To Unit', value: _to, numeric: true, onChanged: (v) => _to = v),
              PickerRow<int>(
                label: 'Function',
                value: _func,
                options: [...Fc.readNames.keys, Fc.reportServerId],
                labelOf: (f) => Fc.readNames[f] ?? '17 Report Server ID',
                onChanged: (f) => setState(() => _func = f),
              ),
              if (_func != Fc.reportServerId)
                TextRow(label: 'Address', value: _address, numeric: true, onChanged: (v) => _address = v),
            ],
          ),
          if (_results.isNotEmpty)
            Section(
              header: scanning ? 'Scanning… $found found' : 'Done · $found found',
              children: [
                for (final r in _results.reversed)
                  CupertinoListTile(
                    leading: Icon(
                      r.found ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.minus_circle,
                      color: context.resolve(r.found ? CupertinoColors.systemGreen : CupertinoColors.systemGrey),
                    ),
                    title: Text('Unit ${r.unit}'),
                    subtitle: Text(r.result, style: monoStyle.copyWith(fontSize: 12)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Paste a register map (JSON or Python REGISTER_DEFINITIONS).
Future<void> showImportPresetsSheet(BuildContext context) =>
    showAdaptiveSheet<void>(context, builder: (context, controller) => _ImportPresets(scrollController: controller));

class _ImportPresets extends ConsumerStatefulWidget {
  const _ImportPresets({required this.scrollController});

  final ScrollController scrollController;

  @override
  ConsumerState<_ImportPresets> createState() => _ImportPresetsState();
}

class _ImportPresetsState extends ConsumerState<_ImportPresets> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _import() {
    try {
      final n = ref.read(modbusProvider.notifier).importPresets(_text.text);
      Navigator.of(context).pop();
      showAlert(context, 'Registers Imported', '$n register definitions were added to the library.');
    } catch (e) {
      showAlert(context, 'Can’t Read the Map', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: sheetBar(context, title: 'Import Registers', action: 'Import', onAction: _import),
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Paste a map like {"battery": {"soc": {"address": 13022, "count": 1, "register_type": "input", '
            '"unit": "%", "description": "State of charge"}}}, or a Python REGISTER_DEFINITIONS = {...}.',
            style: AppText.footnote.copyWith(color: context.resolve(CupertinoColors.secondaryLabel)),
          ),
          const SizedBox(height: 12),
          CupertinoTextField(
            controller: _text,
            minLines: 10,
            maxLines: 20,
            style: monoStyle.copyWith(fontSize: 13),
            placeholder: '{ ... }',
            autocorrect: false,
          ),
        ],
      ),
    );
  }
}
