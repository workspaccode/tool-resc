import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../widgets/hud.dart';
import '../cloud/cloud_link.dart';
import '../modbus_controller.dart';
import '../modbus_models.dart';
import '../protocol/value_format.dart';
import 'form_rows.dart';
import 'setup_panel.dart';
import 'sheets.dart';
import 'views.dart';

enum _Tab { setup, registers, chart, log, library }

/// Modbus Poll: read and write Modbus TCP / RTU devices (inverters, meters,
/// PLCs), and share the live readings to the cloud.
///
/// Narrow screens switch between Setup and the views with tabs; wide
/// screens keep Setup in a side column.
class ModbusScreen extends ConsumerStatefulWidget {
  const ModbusScreen({super.key});

  @override
  ConsumerState<ModbusScreen> createState() => _ModbusScreenState();
}

class _ModbusScreenState extends ConsumerState<ModbusScreen> {
  _Tab _tab = _Tab.setup;

  Future<void> _exportCsv() async {
    final csv = ref.read(modbusProvider.notifier).exportCsv();
    try {
      final saved = await FilePicker.saveFile(
        fileName: 'modbus_poll.csv',
        bytes: utf8.encode(csv),
        mimeType: 'text/csv',
        dialogTitle: 'Export CSV',
        allowedExtensions: const ['csv'],
        type: FileType.custom,
      );
      if (saved != null && mounted) showHud(context, icon: CupertinoIcons.checkmark_circle, message: 'CSV Saved');
    } catch (e) {
      if (mounted) showAlert(context, 'Can’t Save', '$e');
    }
  }

  void _showActions() {
    final s = ref.read(modbusProvider);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) {
        void go(VoidCallback action) {
          Navigator.pop(sheet);
          action();
        }

        return CupertinoActionSheet(
          actions: [
            if (s.connected) ...[
              CupertinoActionSheetAction(
                onPressed: () => go(() => showWriteSheet(context)),
                child: const Text('Write…'),
              ),
              CupertinoActionSheetAction(
                onPressed: () => go(() => showRawSheet(context)),
                child: const Text('Send Message…'),
              ),
              CupertinoActionSheetAction(
                onPressed: () => go(() => showScannerSheet(context)),
                child: const Text('Device Scanner…'),
              ),
            ],
            CupertinoActionSheetAction(
              onPressed: () => go(_pickFormat),
              child: Text('Display: ${s.config.format.label}'),
            ),
            CupertinoActionSheetAction(onPressed: () => go(_exportCsv), child: const Text('Export CSV…')),
          ],
          cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
        );
      },
    );
  }

  Future<void> _pickFormat() async {
    final picked = await pickOption<ValueFormat>(
      context,
      title: 'Display Format',
      options: ValueFormat.values,
      labelOf: (f) => f.label,
      current: ref.read(modbusProvider).config.format,
    );
    if (picked != null) ref.read(modbusProvider.notifier).updateConfig((c) => c.copyWith(format: picked));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(modbusProvider);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Modbus Poll'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusPill(state: s),
            CupertinoButton(
              padding: const EdgeInsets.only(left: 8),
              onPressed: _showActions,
              child: const Icon(CupertinoIcons.ellipsis_circle, size: 24),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 900;
            final tabs = [if (!wide) _Tab.setup, _Tab.registers, _Tab.chart, _Tab.log, _Tab.library];
            final tab = !wide || _tab != _Tab.setup ? _tab : _Tab.registers;
            final content = Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: CupertinoSlidingSegmentedControl<_Tab>(
                    groupValue: tab,
                    onValueChanged: (t) => setState(() => _tab = t!),
                    children: {
                      for (final t in tabs)
                        t: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(switch (t) {
                            _Tab.setup => 'Setup',
                            _Tab.registers => 'Registers',
                            _Tab.chart => 'Chart',
                            _Tab.log => 'Log',
                            _Tab.library => 'Library',
                          }),
                        ),
                    },
                  ),
                ),
                Expanded(
                  child: switch (tab) {
                    _Tab.setup => const _SetupList(),
                    _Tab.registers => const RegistersView(),
                    _Tab.chart => const TrendView(),
                    _Tab.log => const LogView(),
                    _Tab.library => const LibraryView(),
                  },
                ),
              ],
            );
            if (!wide) return content;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 380, child: _SetupList()),
                Container(width: 0.5, color: context.resolve(CupertinoColors.separator)),
                Expanded(child: content),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SetupList extends StatelessWidget {
  const _SetupList();

  @override
  Widget build(BuildContext context) =>
      ListView(children: const [ConnectionSection(), PollsSection(), CloudSection(), SizedBox(height: 24)]);
}

/// Connection + cloud state at a glance.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state});

  final ModbusState state;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (state.link) {
      LinkState.connected => (state.polling ? 'Polling' : 'Connected', CupertinoColors.systemGreen),
      LinkState.connecting => ('Connecting', CupertinoColors.systemOrange),
      LinkState.disconnected => ('Offline', CupertinoColors.systemGrey),
    };
    final c = context.resolve(color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.circle_fill, size: 8, color: c),
          const SizedBox(width: 4),
          Text(
            text,
            style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w600),
          ),
          if (state.cloudState != CloudState.off) ...[
            const SizedBox(width: 6),
            Icon(
              CupertinoIcons.cloud_fill,
              size: 13,
              color: context.resolve(
                state.cloudState == CloudState.live ? CupertinoColors.systemTeal : CupertinoColors.systemOrange,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
