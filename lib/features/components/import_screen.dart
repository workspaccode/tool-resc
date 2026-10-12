import 'package:flutter/material.dart';

import 'components_db.dart';
import 'excel_reader.dart';

/// Shows a preview of the picked Excel file, lets the user pick the sheet and
/// the MPN column, then imports. Pops with the [ImportResult] on success.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, required this.fileName, required this.tables, required this.hasExistingData});

  final String fileName;
  final List<ExcelTable> tables;
  final bool hasExistingData;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
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
      final db = await ComponentsDb.open();
      final result = await db.import(headers: _table.headers, rows: _table.rows, mpnIndex: _mpnIndex, mode: _mode);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل الاستيراد: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mpnFound = _table.guessMpnColumn() >= 0;

    return Scaffold(
      appBar: AppBar(title: const Text('استيراد ملف Excel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.table_chart_outlined),
            title: Text(widget.fileName, textDirection: TextDirection.ltr, textAlign: TextAlign.start),
            subtitle: Text('${_table.rows.length} صف · ${_table.headers.length} حقل'),
          ),
          if (widget.tables.length > 1) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<ExcelTable>(
              initialValue: _table,
              decoration: const InputDecoration(labelText: 'الورقة (Sheet)', border: OutlineInputBorder()),
              items: [for (final t in widget.tables) DropdownMenuItem(value: t, child: Text(t.sheetName))],
              onChanged: (t) => setState(() {
                _table = t!;
                _mpnIndex = _initialMpnIndex(t);
              }),
            ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            key: ValueKey(_table),
            initialValue: _mpnIndex,
            decoration: InputDecoration(
              labelText: 'عمود رقم القطعة (MPN)',
              helperText: mpnFound ? 'تم التعرف عليه تلقائياً' : 'لم يُعثر على عمود MPN، اختره يدوياً',
              border: const OutlineInputBorder(),
            ),
            items: [
              for (var i = 0; i < _table.headers.length; i++)
                DropdownMenuItem(value: i, child: Text(_table.headers[i])),
            ],
            onChanged: (i) => setState(() => _mpnIndex = i!),
          ),
          if (widget.hasExistingData) ...[
            const SizedBox(height: 16),
            Text('توجد بيانات سابقة', style: theme.textTheme.titleSmall),
            RadioGroup<ImportMode>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m!),
              child: const Column(
                children: [
                  RadioListTile(
                    value: ImportMode.replace,
                    title: Text('استبدال'),
                    subtitle: Text('حذف البيانات الحالية والحقول، واستخدام حقول هذا الملف'),
                  ),
                  RadioListTile(
                    value: ImportMode.merge,
                    title: Text('دمج'),
                    subtitle: Text('تحديث المكونات الموجودة بنفس الـ MPN وإضافة الجديدة'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text('معاينة', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _Preview(table: _table, mpnIndex: _mpnIndex),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _importing || _table.rows.isEmpty ? null : _import,
            icon: _importing
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_done),
            label: Text(_importing ? 'جاري الاستيراد...' : 'استيراد ${_table.rows.length} صف'),
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.table, required this.mpnIndex});

  final ExcelTable table;
  final int mpnIndex;

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primaryContainer;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 40,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 40,
          columns: [
            for (var i = 0; i < table.headers.length; i++)
              DataColumn(
                label: Container(
                  color: i == mpnIndex ? highlight : null,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(table.headers[i], style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
          ],
          rows: [
            for (final row in table.rows.take(5))
              DataRow(cells: [for (final c in row) DataCell(Text(c, maxLines: 1, overflow: TextOverflow.ellipsis))]),
          ],
        ),
      ),
    );
  }
}
