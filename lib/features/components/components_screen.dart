import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/glass.dart';
import '../../widgets/icon_tile.dart';
import 'component_detail_screen.dart';
import 'components_providers.dart';
import 'components_repository.dart';
import 'excel_reader.dart';
import 'import_sheet.dart';
import 'label_parser.dart';
import 'scanner_screen.dart';

/// Components tool: search the imported parts by MPN, typed or scanned.
class ComponentsScreen extends ConsumerStatefulWidget {
  const ComponentsScreen({super.key});

  @override
  ConsumerState<ComponentsScreen> createState() => _ComponentsScreenState();
}

class _ComponentsScreenState extends ConsumerState<ComponentsScreen> {
  late final TextEditingController _search;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(searchQueryProvider));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String query) {
    ref.read(scannedLabelProvider.notifier).set(null);
    ref.read(searchQueryProvider.notifier).set(query);
  }

  Future<void> _scan() async {
    final label = await Navigator.of(context).push<ScannedLabel>(
      CupertinoPageRoute(fullscreenDialog: true, builder: (_) => const ScannerScreen()),
    );
    if (label == null || !mounted) return;

    // OCR may misread similar characters (O/0, I/1...); match tolerantly and
    // show the MPN as stored in the database.
    final repo = ref.read(componentsRepositoryProvider);
    final key = repo.matchKey(label.mpn);
    final rows = key == null ? const <Component>[] : await repo.rowsFor(key);
    if (!mounted) return;

    final mpn = rows.firstOrNull?.mpn ?? label.mpn;
    _search.text = mpn;
    ref.read(searchQueryProvider.notifier).set(mpn);
    ref.read(scannedLabelProvider.notifier).set(label);

    // One row opens directly; several rows for the MPN stay listed.
    if (rows.isEmpty) {
      HapticFeedback.vibrate();
    } else {
      HapticFeedback.heavyImpact();
      if (rows.length == 1) _open(rows.single);
    }
  }

  void _open(Component c) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ComponentDetailScreen(
          component: c,
          mpnField: ref.read(catalogProvider).mpnField,
        ),
      ),
    );
  }

  Future<void> _pickExcel() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (files.isEmpty || !mounted) return;
    final file = files.first;

    List<ExcelTable> tables;
    setState(() => _reading = true);
    try {
      tables = await readExcel(await file.readAsBytes());
    } catch (e) {
      if (mounted) _alert('Can’t Read File', '$e');
      return;
    } finally {
      if (mounted) setState(() => _reading = false);
    }
    if (!mounted) return;
    if (tables.isEmpty) {
      _alert('Empty File', 'The file doesn’t contain any data.');
      return;
    }

    final result = await showImportSheet(
      context,
      fileName: file.name,
      tables: tables,
    );
    if (result == null || !mounted) return;
    _alert(
      'Import Complete',
      [
        '${result.inserted} rows added',
        if (result.updated > 0) '${result.updated} rows updated',
        if (result.removed > 0) '${result.removed} old rows removed',
        if (result.skipped > 0) '${result.skipped} rows skipped (empty MPN)',
      ].join('\n'),
    );
  }

  void _alert(String title, String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: Navigator.of(context).pop,
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showMenu() {
    final hasData = !ref.read(catalogProvider).isEmpty;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              _pickExcel();
            },
            child: const Text('Import Excel File'),
          ),
          if (hasData)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(sheet);
                _confirmClear();
              },
              child: const Text('Delete All Components'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  void _confirmClear() {
    showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('Delete All Components?'),
        content: const Text(
          'All imported components and fields will be removed from this device.',
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(dialog);
              _search.clear();
              ref.read(catalogProvider.notifier).clear();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final menuButton = CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _reading ? null : _showMenu,
      child: _reading
          ? const CupertinoActivityIndicator()
          : const Icon(CupertinoIcons.ellipsis_circle, size: 26),
    );

    if (catalog.isEmpty) {
      return CupertinoPageScaffold(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(
              largeTitle: const Text('Components'),
              previousPageTitle: 'Tools',
              trailing: menuButton,
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(loading: _reading, onImport: _pickExcel),
            ),
          ],
        ),
      );
    }

    final query = ref.watch(searchQueryProvider);
    final label = ref.watch(scannedLabelProvider);
    // Keep showing the previous results while the next search runs.
    final results =
        ref.watch(searchResultsProvider).value ?? SearchResults.empty;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return CupertinoPageScaffold(
      child: Stack(
        children: [
          CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              CupertinoSliverNavigationBar.search(
                largeTitle: const Text('Components'),
                previousPageTitle: 'Tools',
                trailing: menuButton,
                searchField: CupertinoSearchTextField(
                  controller: _search,
                  placeholder: 'Search by MPN',
                  autocorrect: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  enableIMEPersonalizedLearning: false,
                  onChanged: _setQuery,
                  onSuffixTap: () {
                    _search.clear();
                    _setQuery('');
                  },
                ),
              ),
              if (label != null)
                SliverToBoxAdapter(
                  child: _ScanResultCard(
                    label: label,
                    mpn: query,
                    found: ref.read(componentsRepositoryProvider).matchKey(label.mpn) != null,
                  ),
                ),
              if (query.trim().isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Hint(catalog: catalog),
                )
              else if (results.total == 0)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _NoResults(query: query),
                )
              else
                SliverToBoxAdapter(
                  child: Section(
                    header: results.total > results.items.length
                        ? 'TOP ${results.items.length} OF ${results.total} RESULTS'
                        : '${results.total} ${results.total == 1 ? 'RESULT' : 'RESULTS'}',
                    children: [
                      for (final c in results.items)
                        _ResultRow(
                          component: c,
                          mpnField: catalog.mpnField,
                          exact: c.mpnKey == mpnKey(query),
                          onTap: () => _open(c),
                        ),
                    ],
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.only(bottom: 110 + bottomInset),
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 16,
            child: Center(child: _ScanButton(onPressed: _scan)),
          ),
        ],
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Scan label',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onPressed();
        },
        child: Glass(
          radius: 30,
          tint: CupertinoColors.systemBlue,
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.qrcode_viewfinder,
                color: CupertinoColors.white,
                size: 24,
              ),
              const SizedBox(width: 10),
              Text(
                'Scan Label',
                style: AppText.headline.copyWith(color: CupertinoColors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.component,
    required this.mpnField,
    required this.exact,
    required this.onTap,
  });

  final Component component;
  final String? mpnField;
  final bool exact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The first couple of other fields as a summary line.
    final summary = component.values.entries
        .where((e) => e.key != mpnField)
        .take(2)
        .map((e) => e.value)
        .join(' · ');
    return CupertinoListTile(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 14, 10),
      leading: IconTile(
        icon: exact
            ? CupertinoIcons.checkmark_seal_fill
            : CupertinoIcons.cube_box_fill,
        color: exact ? CupertinoColors.systemGreen : CupertinoColors.systemGrey,
      ),
      title: Text(component.mpn, style: AppText.mpn),
      subtitle: summary.isEmpty
          ? null
          : Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const CupertinoListTileChevron(),
      onTap: onTap,
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  const _ScanResultCard({required this.label, required this.mpn, required this.found});

  final ScannedLabel label;

  /// The MPN as stored when found, else as read from the label.
  final String mpn;
  final bool found;

  @override
  Widget build(BuildContext context) {
    final color = found
        ? CupertinoColors.systemGreen
        : CupertinoColors.systemRed;
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final details = [
      ('Read from', label.source == LabelSource.text ? 'MPN text' : 'QR code'),
      if (found && mpnKey(label.mpn) != mpnKey(mpn)) ('Read as', label.mpn),
      if (label.supplierPart != null) ('Supplier', label.supplierPart!),
      if (label.quantity != null) ('Qty', label.quantity!),
      if (label.orderNumber != null) ('Order', label.orderNumber!),
    ];

    return Section(
      header: 'SCANNED LABEL',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    found
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.xmark_octagon_fill,
                    color: context.resolve(color),
                    size: 30,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          found ? 'In Database' : 'Not in Database',
                          style: AppText.footnote.copyWith(
                            color: context.resolve(color),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(mpn, style: AppText.mpn),
                      ],
                    ),
                  ),
                ],
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (name, value) in details)
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          shape: const StadiumBorder(),
                          color: context.resolve(
                            CupertinoColors.tertiarySystemFill,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$name  ',
                                  style: TextStyle(color: secondary),
                                ),
                                TextSpan(
                                  text: value,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            style: AppText.footnote,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.catalog});

  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 140),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.barcode_viewfinder,
            size: 64,
            color: context.resolve(CupertinoColors.tertiaryLabel),
          ),
          const SizedBox(height: 16),
          const Text('Find a Component', style: AppText.title2),
          const SizedBox(height: 6),
          Text(
            'Search by MPN, or scan the label on a reel or bag by its “MPN:” line or QR code.',
            textAlign: TextAlign.center,
            style: AppText.subheadline.copyWith(color: secondary),
          ),
          const SizedBox(height: 20),
          Text(
            '${catalog.count} rows · ${catalog.mpnCount} MPNs · ${catalog.fields.length} fields',
            style: AppText.footnote.copyWith(
              color: secondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 140),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.search,
            size: 56,
            color: context.resolve(CupertinoColors.tertiaryLabel),
          ),
          const SizedBox(height: 16),
          Text(
            'No Results for “$query”',
            style: AppText.title3,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Check the spelling or try part of the MPN.',
            textAlign: TextAlign.center,
            style: AppText.subheadline.copyWith(
              color: context.resolve(CupertinoColors.secondaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.loading, required this.onImport});

  final bool loading;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const IconTile(
            icon: CupertinoIcons.tray_arrow_down_fill,
            color: CupertinoColors.systemBlue,
            size: 84,
          ),
          const SizedBox(height: 24),
          const Text('No Components', style: AppText.title1),
          const SizedBox(height: 8),
          Text(
            'Import an Excel file. Each column becomes a field you can search and scan against.',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: context.resolve(CupertinoColors.secondaryLabel),
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              borderRadius: BorderRadius.circular(14),
              onPressed: loading ? null : onImport,
              child: loading
                  ? const CupertinoActivityIndicator(
                      color: CupertinoColors.white,
                    )
                  : const Text(
                      'Import Excel File',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
