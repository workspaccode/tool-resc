import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/adaptive_sheet.dart';
import '../../widgets/icon_tile.dart';
import 'component_lists.dart';
import 'components_providers.dart';
import 'components_repository.dart';
import 'excel_reader.dart';
import '../sync/sync_controller.dart';

/// Picks an .xlsx file, shows the import sheet, and reports the result.
/// [onReading] is told while the file is being read (for a spinner).
Future<ImportResult?> pickAndImportExcel(BuildContext context, {ValueChanged<bool>? onReading}) async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
  if (files.isEmpty || !context.mounted) return null;
  final file = files.first;

  List<ExcelTable> tables;
  onReading?.call(true);
  try {
    tables = await readExcel(await file.readAsBytes());
  } catch (e) {
    if (context.mounted) _alert(context, 'Can’t Read File', '$e');
    return null;
  } finally {
    onReading?.call(false);
  }
  if (!context.mounted) return null;
  if (tables.isEmpty) {
    _alert(context, 'Empty File', 'The file doesn’t contain any data.');
    return null;
  }

  final result = await showImportSheet(context, fileName: file.name, tables: tables);
  if (result != null && context.mounted) {
    _alert(
      context,
      'Import Complete',
      [
        '${result.inserted} rows added',
        if (result.updated > 0) '${result.updated} rows updated',
        if (result.removed > 0) '${result.removed} old rows removed',
        if (result.skipped > 0) '${result.skipped} rows skipped (empty search column)',
      ].join('\n'),
    );
  }
  return result;
}

void _alert(BuildContext context, String title, String message) {
  showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
      ],
    ),
  );
}

/// Shows the import sheet; completes with the result, or null if cancelled.
Future<ImportResult?> showImportSheet(
  BuildContext context, {
  required String fileName,
  required List<ExcelTable> tables,
}) {
  return showAdaptiveSheet<ImportResult>(
    context,
    builder: (context, controller) => _ImportSheet(fileName: fileName, tables: tables, scrollController: controller),
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

  /// Import into a new list (default when the current list has data), or
  /// into the current one.
  late bool _newList = !ref.read(catalogProvider).isEmpty;
  late final _listName = TextEditingController(text: p.basenameWithoutExtension(widget.fileName));

  @override
  void dispose() {
    _listName.dispose();
    super.dispose();
  }

  static int _initialMpnIndex(ExcelTable t) {
    final guess = t.guessMpnColumn();
    return guess >= 0 ? guess : 0;
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    final lists = ref.read(listsProvider.notifier);
    final currentIsEmpty = ref.read(catalogProvider).isEmpty;
    String? createdId;
    try {
      if (_newList) {
        createdId = await lists.create(_listName.text);
      } else if (currentIsEmpty) {
        // First import into an empty list: name it after the file.
        lists.rename(ref.read(listsProvider).activeId, _listName.text);
      }
      final mode = _newList || currentIsEmpty ? ImportMode.replace : _mode;
      final result = await ref
          .read(catalogProvider.notifier)
          .import(headers: _table.headers, rows: _table.rows, mpnIndex: _mpnIndex, mode: mode);
      ref
          .read(syncProvider.notifier)
          .recordImport(
            list: ref.read(listsProvider).active,
            headers: _table.headers,
            rows: _table.rows,
            mpnIndex: _mpnIndex,
            mode: mode,
          );
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (createdId != null) await lists.delete(createdId);
      if (!mounted) return;
      setState(() => _importing = false);
      _alert(context, 'Import Failed', '$e');
    }
  }

  Widget _destinationSection(bool hasData) {
    final current = ref.watch(listsProvider).active;
    final nameField = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: CupertinoTextField(
        controller: _listName,
        placeholder: 'List name',
        prefix: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Icon(CupertinoIcons.list_bullet, size: 18, color: context.resolve(CupertinoColors.secondaryLabel)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );

    if (!hasData) {
      return Section(
        header: 'List name',
        footer: 'Each import can be its own list. Switch between lists to check different orders or BOMs.',
        children: [nameField],
      );
    }

    return Section(
      header: 'Import to',
      footer: _newList
          ? 'Creates a new list. “${current.name}” stays as it is.'
          : _mode == ImportMode.replace
          ? 'Deletes everything in “${current.name}”, then uses the fields in this file.'
          : 'Updates rows in “${current.name}” with the same value in the search column, adds new ones, and adds any new fields.',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: CupertinoSlidingSegmentedControl<bool>(
            groupValue: _newList,
            onValueChanged: (v) => setState(() => _newList = v!),
            children: {
              true: const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('New List')),
              false: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Text(current.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            },
          ),
        ),
        if (_newList)
          nameField
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
    );
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
          _destinationSection(hasData),
          Section(
            header: 'FIELDS',
            footer: detected
                ? 'Each column becomes a field. The marked column is what searches and scans match against. It was picked automatically; tap another column to change it.'
                : 'Each column becomes a field. Tap the column that searches and scans should match against (for example, the part number).',
            children: [
              for (var i = 0; i < _table.headers.length; i++)
                _CheckRow(
                  title: _table.headers[i],
                  info: _sample(i),
                  badge: i == _mpnIndex ? 'SEARCH' : null,
                  selected: i == _mpnIndex,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _mpnIndex = i);
                  },
                ),
            ],
          ),
          _MpnStats(table: _table, mpnIndex: _mpnIndex),
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

/// What the chosen MPN column means for the import, so a wrong column is
/// obvious before importing.
class _MpnStats extends StatelessWidget {
  const _MpnStats({required this.table, required this.mpnIndex});

  final ExcelTable table;
  final int mpnIndex;

  @override
  Widget build(BuildContext context) {
    final keys = table.rows.map((r) => mpnKey(r[mpnIndex])).toList();
    final empty = keys.where((k) => k.isEmpty).length;
    final saved = keys.length - empty;
    final unique = keys.where((k) => k.isNotEmpty).toSet().length;
    final warn = context.resolve(CupertinoColors.systemOrange);

    return Section(
      header: 'Will be saved',
      footer: [
        if (empty > 0) 'Rows with an empty search column can’t be found, so they are skipped.',
        if (unique > 0 && unique * 2 < saved)
          'Many rows share the same value. Each row is still saved. If this is unexpected, check the search column.',
      ].join(' ').nullIfEmpty,
      children: [
        CupertinoListTile(title: const Text('Rows'), additionalInfo: Text('$saved')),
        CupertinoListTile(title: const Text('Different values'), additionalInfo: Text('$unique')),
        if (empty > 0)
          CupertinoListTile(
            leading: Icon(CupertinoIcons.exclamationmark_triangle_fill, color: warn, size: 22),
            title: const Text('Skipped (empty)'),
            additionalInfo: Text('$empty', style: TextStyle(color: warn)),
          ),
      ],
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
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
