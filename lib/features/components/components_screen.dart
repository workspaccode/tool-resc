import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'component_detail_screen.dart';
import 'components_db.dart';
import 'excel_reader.dart';
import 'import_screen.dart';
import 'label_parser.dart';
import 'scanner_screen.dart';

/// Components tool: search the imported parts by MPN, typed or scanned.
class ComponentsScreen extends StatefulWidget {
  const ComponentsScreen({super.key});

  @override
  State<ComponentsScreen> createState() => _ComponentsScreenState();
}

class _ComponentsScreenState extends State<ComponentsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  ComponentsDb? _db;
  int _count = 0;
  List<Component> _results = [];
  ScannedLabel? _scanned;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = await ComponentsDb.open();
    final count = await db.count();
    if (!mounted) return;
    setState(() {
      _db = db;
      _count = count;
      _loading = false;
    });
  }

  void _onQueryChanged(String _) {
    _scanned = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _runSearch);
  }

  Future<List<Component>> _runSearch() async {
    final query = _search.text.trim();
    final results = query.isEmpty ? <Component>[] : await _db!.search(query);
    if (mounted) setState(() => _results = results);
    return results;
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (raw == null || !mounted) return;
    final label = ScannedLabel.parse(raw);
    _search.text = label.mpn;
    setState(() => _scanned = label);
    final results = await _runSearch();

    // A single exact match goes straight to its details.
    if (results.length == 1 && mpnKey(results.first.mpn) == mpnKey(label.mpn) && mounted) {
      _open(results.first);
    }
  }

  void _open(Component c) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ComponentDetailScreen(component: c)));
  }

  Future<void> _pickExcel() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (files.isEmpty || !mounted) return;
    final file = files.first;

    final messenger = ScaffoldMessenger.of(context);
    List<ExcelTable> tables;
    try {
      setState(() => _loading = true);
      tables = await readExcel(await file.readAsBytes());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('تعذرت قراءة الملف: $e')));
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    if (tables.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('الملف فارغ')));
      return;
    }

    final result = await Navigator.of(context).push<ImportResult>(
      MaterialPageRoute(
        builder: (_) => ImportScreen(fileName: file.name, tables: tables, hasExistingData: _count > 0),
      ),
    );
    if (result == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'تمت إضافة ${result.inserted}'
          '${result.updated > 0 ? ' · تحديث ${result.updated}' : ''}'
          '${result.skipped > 0 ? ' · تجاهل ${result.skipped} بدون MPN' : ''}',
        ),
      ),
    );
    await _load();
    await _runSearch();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف كل المكونات؟'),
        content: const Text('سيتم حذف جميع البيانات والحقول المستوردة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await _db!.clear();
    _search.clear();
    setState(() {
      _results = [];
      _scanned = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('المكونات'),
        actions: [
          IconButton(tooltip: 'استيراد Excel', icon: const Icon(Icons.upload_file), onPressed: _loading ? null : _pickExcel),
          PopupMenuButton<void>(
            itemBuilder: (_) => [
              PopupMenuItem(enabled: _count > 0, onTap: _confirmClear, child: const Text('حذف كل البيانات')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _count == 0
              ? _EmptyState(onImport: _pickExcel)
              : _buildSearch(context),
      floatingActionButton: _count == 0 || _loading
          ? null
          : FloatingActionButton.extended(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('مسح')),
    );
  }

  Widget _buildSearch(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: _onQueryChanged,
            textDirection: TextDirection.ltr,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'ابحث برقم MPN',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _onQueryChanged('');
                      },
                    ),
              border: const OutlineInputBorder(),
              helperText: '$_count مكوّن في قاعدة البيانات',
            ),
          ),
        ),
        if (_scanned != null) _ScannedCard(label: _scanned!, found: _results.isNotEmpty),
        Expanded(
          child: query.isEmpty
              ? Center(child: Text('اكتب رقم القطعة أو امسح الملصق', style: theme.textTheme.bodyLarge))
              : _results.isEmpty
                  ? Center(child: Text('لا توجد نتائج لـ "$query"', style: theme.textTheme.bodyLarge))
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _ResultTile(
                        component: _results[i],
                        exact: mpnKey(_results[i].mpn) == mpnKey(query),
                        onTap: () => _open(_results[i]),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.component, required this.exact, required this.onTap});

  final Component component;
  final bool exact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Show the first couple of non-MPN fields as a summary.
    final summary = component.values.entries
        .where((e) => e.value.isNotEmpty && e.value != component.mpn)
        .take(2)
        .map((e) => e.value)
        .join(' · ');
    return ListTile(
      leading: Icon(exact ? Icons.check_circle : Icons.memory, color: exact ? Colors.green : null),
      title: Text(component.mpn, textDirection: TextDirection.ltr, textAlign: TextAlign.start),
      subtitle: summary.isEmpty ? null : Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_left),
      onTap: onTap,
    );
  }
}

class _ScannedCard extends StatelessWidget {
  const _ScannedCard({required this.label, required this.found});

  final ScannedLabel label;
  final bool found;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      if (label.supplierPart != null) 'كود المورد: ${label.supplierPart}',
      if (label.quantity != null) 'الكمية: ${label.quantity}',
      if (label.orderNumber != null) 'الطلب: ${label.orderNumber}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: found ? scheme.secondaryContainer : scheme.errorContainer,
      child: ListTile(
        leading: Icon(found ? Icons.verified : Icons.error_outline),
        title: Text(found ? 'تم المسح: ${label.mpn}' : 'غير موجود: ${label.mpn}'),
        subtitle: details.isEmpty ? null : Text(details),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 72, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('لا توجد مكونات بعد', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'استورد ملف Excel. سيتحول كل عمود فيه إلى حقل في قاعدة البيانات.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: onImport, icon: const Icon(Icons.upload_file), label: const Text('استيراد Excel')),
          ],
        ),
      ),
    );
  }
}
