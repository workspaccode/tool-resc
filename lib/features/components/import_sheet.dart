import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/icon_tile.dart';
import 'components_providers.dart';
import 'components_repository.dart';
import 'excel_reader.dart';

/// Shows the import sheet; completes with the result, or null if cancelled.
Future<ImportResult?> showImportSheet(
  BuildContext context, {
  required String fileName,
  required List<ExcelTable> tables,
}) {
  return showCupertinoSheet<ImportResult>(
    context: context,
    scrollableBuilder: (context, controller) =>
        _ImportSheet(fileName: fileName, tables: tables, scrollController: controller),
  );
}

class _ImportSheet extends ConsumerStatefulWidget {
  const _ImportSheet({required this.fileName, required this.tables, required this.scrollController});

  final String fileName;
  final List<ExcelTable> tables;
  final ScrollController scrollController;

  @override
  ConsumerState<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<_ImportSheet> {
  late ExcelTable _table = widget.tables.first;
  late int _mpnIndex = _initialMpnIndex(_table);
  ImportMode _mode = ImportMode.replace;
  bool _importing = false;

  static int _initialMpnIndex(ExcelTable t) {
    final guess = t.guessMpnColumn();
    return guess >= 0 ? guess : 0;
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final result = await ref
          .read(catalogProvider.notifier)
          .import(headers: _table.headers, rows: _table.rows, mpnIndex: _mpnIndex, mode: _mode);
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Import Failed'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(isDefaultAction: true, onPressed: Navigator.of(context).pop, child: const Text('OK')),
          ],
        ),
      );
    }
  }

  /// First non-empty value of a column, shown as a hint next to each field.
  String _sample(int column) => _table.rows.map((r) => r[column]).firstWhere((v) => v.isNotEmpty, orElse: () => '');

  @override
  Widget build(BuildContext context) {
    final hasData = !ref.watch(catalogProvider).isEmpty;
    final detected = _table.guessMpnColumn() >= 0;
    final secondary = context.resolve(CupertinoColors.secondaryLabel);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        middle: const Text('Import'),
        trailing: _importing
            ? const CupertinoActivityIndicator()
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _table.rows.isEmpty ? null : _import,
                child: const Text('Import', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
      ),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Section(
            children: [
              CupertinoListTile(
                leading: const IconTile(icon: CupertinoIcons.table, color: CupertinoColors.systemGreen),
                title: Text(widget.fileName),
                subtitle: Text('${_table.rows.length} rows · ${_table.headers.length} fields'),
              ),
            ],
          ),
          if (widget.tables.length > 1)
            Section(
              header: 'SHEET',
              children: [
                for (final t in widget.tables)
                  _CheckRow(
                    title: t.sheetName,
                    info: '${t.rows.length} rows',
                    selected: t == _table,
                    onTap: () => setState(() {
                      _table = t;
                      _mpnIndex = _initialMpnIndex(t);
                    }),
                  ),
              ],
            ),
          if (hasData)
            Section(
              header: 'EXISTING DATA',
              footer: _mode == ImportMode.replace
                  ? 'Deletes all components and fields, then uses the fields in this file.'
                  : 'Updates components with the same MPN, adds new ones, and adds any new fields.',
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: CupertinoSlidingSegmentedControl<ImportMode>(
                    groupValue: _mode,
                    onValueChanged: (m) => setState(() => _mode = m!),
                    children: const {
                      ImportMode.replace: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Replace')),
                      ImportMode.merge: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Merge')),
                    },
                  ),
                ),
              ],
            ),
          Section(
            header: 'FIELDS',
            footer: detected
                ? 'Each column becomes a field. The MPN column was detected automatically. Tap another field to change it.'
                : 'Each column becomes a field. No MPN column was found. Tap the field that holds the part number.',
            children: [
              for (var i = 0; i < _table.headers.length; i++)
                _CheckRow(
                  title: _table.headers[i],
                  info: _sample(i),
                  badge: i == _mpnIndex ? 'MPN' : null,
                  selected: i == _mpnIndex,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _mpnIndex = i);
                  },
                ),
            ],
          ),
          if (_table.rows.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 16, 36, 8),
              child: Text('PREVIEW', style: AppText.footnote.copyWith(color: secondary)),
            ),
            _Preview(table: _table, mpnIndex: _mpnIndex),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.title, required this.selected, required this.onTap, this.info, this.badge});

  final String title;
  final String? info;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final blue = context.resolve(CupertinoColors.systemBlue);
    return CupertinoListTile(
      title: Row(
        children: [
          Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
          if (badge != null) ...[
            const SizedBox(width: 8),
            DecoratedBox(
              decoration: ShapeDecoration(shape: const StadiumBorder(), color: blue.withValues(alpha: 0.15)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                child: Text(
                  badge!,
                  style: AppText.caption.copyWith(color: blue, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
      additionalInfo: info == null || info!.isEmpty
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(info!, overflow: TextOverflow.ellipsis),
            ),
      trailing: SizedBox(width: 22, child: selected ? Icon(CupertinoIcons.checkmark_alt, color: blue, size: 22) : null),
      onTap: onTap,
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.table, required this.mpnIndex});

  final ExcelTable table;
  final int mpnIndex;

  @override
  Widget build(BuildContext context) {
    final rows = table.rows.take(5).toList();
    final separator = context.resolve(CupertinoColors.separator);
    final highlight = context.resolve(CupertinoColors.systemBlue).withValues(alpha: 0.12);

    Widget cell(String text, {bool header = false, bool mpn = false}) => Container(
      width: 150,
      color: mpn ? highlight : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (header ? AppText.footnote.copyWith(fontWeight: FontWeight.w600) : AppText.footnote).copyWith(
          color: context.resolve(header ? CupertinoColors.label : CupertinoColors.secondaryLabel),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: context.resolve(CupertinoColors.secondarySystemGroupedBackground),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < table.headers.length; i++)
                      cell(table.headers[i], header: true, mpn: i == mpnIndex),
                  ],
                ),
                for (final r in rows) ...[
                  Container(height: 0.5, width: 150.0 * table.headers.length, color: separator),
                  Row(children: [for (var i = 0; i < r.length; i++) cell(r[i], mpn: i == mpnIndex)]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
