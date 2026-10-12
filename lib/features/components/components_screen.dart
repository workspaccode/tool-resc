import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../widgets/clickable_tile.dart';
import '../../widgets/glass.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/section.dart';
import 'component_detail_screen.dart';
import 'components_providers.dart';
import 'components_repository.dart';
import 'excel_reader.dart';
import 'import_sheet.dart';
import 'keyboard_scanner.dart';
import 'label_parser.dart';
import 'scanner_screen.dart';

/// Components tool: search the imported parts by MPN, typed or scanned.
///
/// Phones scan with the camera; desktops (and any device with a hardware
/// scanner attached) take scans from a USB scanner in keyboard mode. On wide
/// screens the list and the selected component show side by side.
class ComponentsScreen extends ConsumerStatefulWidget {
  const ComponentsScreen({super.key});

  @override
  ConsumerState<ComponentsScreen> createState() => _ComponentsScreenState();
}

class _ComponentsScreenState extends ConsumerState<ComponentsScreen> {
  late final TextEditingController _search;
  final _searchFocus = FocusNode();
  bool _reading = false;

  /// Split layout: the list plus a detail pane instead of pushed pages.
  bool _wide = false;
  Component? _selected;

  /// When the last hardware-scanner scan arrived, to flash the status pill.
  DateTime? _lastScan;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(searchQueryProvider));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _setQuery(String query) {
    ref.read(scannedLabelProvider.notifier).set(null);
    ref.read(searchQueryProvider.notifier).set(query);
  }

  void _clearSearch() {
    _search.clear();
    _setQuery('');
  }

  Future<void> _scanWithCamera() async {
    final label = await Navigator.of(context)
        .push<ScannedLabel>(CupertinoPageRoute(fullscreenDialog: true, builder: (_) => const ScannerScreen()));
    if (label != null && mounted) await _handleLabel(label);
  }

  void _onHardwareScan(String text) {
    setState(() => _lastScan = DateTime.now());
    _handleLabel(ScannedLabel.parse(text));
  }

  /// Shows a scanned label: fills the search with the MPN as stored, and
  /// opens it when it has a single row.
  Future<void> _handleLabel(ScannedLabel label) async {
    final repo = ref.read(componentsRepositoryProvider);
    final key = repo.matchKey(label.mpn);
    final rows = key == null ? const <Component>[] : await repo.rowsFor(key);
    if (!mounted) return;

    final mpn = rows.firstOrNull?.mpn ?? label.mpn;
    _search.text = mpn;
    ref.read(searchQueryProvider.notifier).set(mpn);
    ref.read(scannedLabelProvider.notifier).set(label);

    if (rows.isEmpty) {
      HapticFeedback.vibrate();
      if (_wide) setState(() => _selected = null);
    } else {
      HapticFeedback.heavyImpact();
      if (rows.length == 1 || _wide) _open(rows.first);
    }
  }

  /// Enter in the search field opens the part if the MPN matches exactly.
  Future<void> _submit(String text) async {
    final rows = await ref.read(componentsRepositoryProvider).rowsFor(mpnKey(text));
    if (mounted && rows.isNotEmpty) _open(rows.first);
  }

  void _open(Component c) {
    if (_wide) {
      setState(() => _selected = c);
      return;
    }
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ComponentDetailScreen(component: c, mpnField: ref.read(catalogProvider).mpnField),
      ),
    );
  }

  Future<void> _pickExcel() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
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

    final result = await showImportSheet(context, fileName: file.name, tables: tables);
    if (result == null || !mounted) return;
    setState(() => _selected = null);
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
          CupertinoDialogAction(isDefaultAction: true, onPressed: Navigator.of(context).pop, child: const Text('OK')),
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
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
      ),
    );
  }

  void _confirmClear() {
    showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('Delete All Components?'),
        content: const Text('All imported components and fields will be removed from this device.'),
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
              setState(() => _selected = null);
              ref.read(catalogProvider.notifier).clear();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Toolbar actions: separate buttons with a mouse, one menu on touch.
  Widget _actions(bool hasData) {
    if (_reading) return const CupertinoActivityIndicator();
    if (!isDesktop) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: _showMenu,
        child: const Icon(CupertinoIcons.ellipsis_circle, size: 26),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolbarButton(icon: CupertinoIcons.square_arrow_down, tooltip: 'Import Excel File', onPressed: _pickExcel),
        if (hasData)
          _ToolbarButton(icon: CupertinoIcons.trash, tooltip: 'Delete All Components', onPressed: _confirmClear),
      ],
    );
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final mac = isMacOS;
    SingleActivator cmd(LogicalKeyboardKey key) => SingleActivator(key, meta: mac, control: !mac);
    return {
      cmd(LogicalKeyboardKey.keyF): _searchFocus.requestFocus,
      cmd(LogicalKeyboardKey.keyO): _pickExcel,
      const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
    };
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardScannerListener(
      onScan: _onHardwareScan,
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // No data yet: the empty state uses the full width.
              _wide = constraints.maxWidth >= kWideLayout && !ref.watch(catalogProvider).isEmpty;
              if (!_wide) return _buildList(context);

              final listWidth = (constraints.maxWidth * 0.4).clamp(360.0, 460.0);
              final selected = _selected;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: listWidth, child: _buildList(context)),
                  Container(width: 0.5, color: context.resolve(CupertinoColors.separator)),
                  Expanded(
                    child: selected == null
                        ? const _DetailPlaceholder()
                        : ComponentDetailScreen(
                            key: ValueKey(selected.key),
                            component: selected,
                            mpnField: ref.watch(catalogProvider).mpnField,
                            embedded: true,
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final catalog = ref.watch(catalogProvider);

    if (catalog.isEmpty) {
      return CupertinoPageScaffold(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverNavigationBar(
              largeTitle: const Text('Components'),
              previousPageTitle: 'Tools',
              trailing: _actions(false),
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
    final results = ref.watch(searchResultsProvider).value ?? SearchResults.empty;
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
                trailing: _actions(true),
                searchField: CupertinoSearchTextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  autofocus: isDesktop,
                  placeholder: isDesktop ? 'Search by MPN  (${_shortcutLabel('F')})' : 'Search by MPN',
                  autocorrect: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  enableIMEPersonalizedLearning: false,
                  onChanged: _setQuery,
                  onSubmitted: _submit,
                  onSuffixTap: _clearSearch,
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
                SliverFillRemaining(hasScrollBody: false, child: _Hint(catalog: catalog))
              else if (results.total == 0)
                SliverFillRemaining(hasScrollBody: false, child: _NoResults(query: query))
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
                          selected: _wide && c.key == _selected?.key,
                          onTap: () => _open(c),
                        ),
                    ],
                  ),
                ),
              SliverPadding(padding: EdgeInsets.only(bottom: 110 + bottomInset)),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 16,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: isDesktop ? _ScannerStatus(lastScan: _lastScan) : _ScanButton(onPressed: _scanWithCamera),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _shortcutLabel(String key) => isMacOS ? '⌘$key' : 'Ctrl+$key';

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(36, 36),
        onPressed: onPressed,
        child: Icon(icon, size: 24),
      ),
    );
  }
}

/// Desktop replacement for the camera button: shows the USB scanner is
/// listening, and flashes when a scan arrives.
class _ScannerStatus extends StatelessWidget {
  const _ScannerStatus({required this.lastScan});

  final DateTime? lastScan;

  @override
  Widget build(BuildContext context) {
    final green = context.resolve(CupertinoColors.systemGreen);
    final label = context.resolve(CupertinoColors.label);
    return TweenAnimationBuilder<double>(
      key: ValueKey(lastScan),
      tween: Tween(begin: lastScan == null ? 0 : 1, end: 0),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOut,
      builder: (context, flash, child) => Transform.scale(scale: 1 + flash * 0.06, child: child),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: green,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: green.withValues(alpha: 0.6), blurRadius: 8)],
              ),
              child: const SizedBox.square(dimension: 9),
            ),
            const SizedBox(width: 10),
            Icon(CupertinoIcons.barcode, size: 20, color: label),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Scanner ready — scan a label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.subheadline.copyWith(color: label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailPlaceholder extends StatelessWidget {
  const _DetailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.resolve(CupertinoColors.systemGroupedBackground),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.cube_box, size: 64, color: context.resolve(CupertinoColors.tertiaryLabel)),
            const SizedBox(height: 14),
            const Text('No Component Selected', style: AppText.title3),
            const SizedBox(height: 6),
            Text(
              'Scan a label or pick a result to see its fields.',
              style: AppText.subheadline.copyWith(color: context.resolve(CupertinoColors.secondaryLabel)),
            ),
          ],
        ),
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
              const Icon(CupertinoIcons.qrcode_viewfinder, color: CupertinoColors.white, size: 24),
              const SizedBox(width: 10),
              Text('Scan Label', style: AppText.headline.copyWith(color: CupertinoColors.white)),
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
    required this.selected,
    required this.onTap,
  });

  final Component component;
  final String? mpnField;
  final bool exact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The first couple of other fields as a summary line.
    final summary = component.values.entries.where((e) => e.key != mpnField).take(2).map((e) => e.value).join(' · ');
    return ClickableTile(
      selected: selected,
      padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 14, 10),
      leading: IconTile(
        icon: exact ? CupertinoIcons.checkmark_seal_fill : CupertinoIcons.cube_box_fill,
        color: exact ? CupertinoColors.systemGreen : CupertinoColors.systemGrey,
      ),
      title: Text(component.mpn, style: AppText.mpn),
      subtitle: summary.isEmpty ? null : Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final color = found ? CupertinoColors.systemGreen : CupertinoColors.systemRed;
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final details = [
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
                    found ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.xmark_octagon_fill,
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
                          style: AppText.footnote.copyWith(color: context.resolve(color), fontWeight: FontWeight.w600),
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
                          color: context.resolve(CupertinoColors.tertiarySystemFill),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$name  ',
                                  style: TextStyle(color: secondary),
                                ),
                                TextSpan(
                                  text: value,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
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
          Icon(CupertinoIcons.barcode_viewfinder, size: 64, color: context.resolve(CupertinoColors.tertiaryLabel)),
          const SizedBox(height: 16),
          const Text('Find a Component', style: AppText.title2),
          const SizedBox(height: 6),
          Text(
            isDesktop
                ? 'Type an MPN, or scan the label on a reel or bag with your USB scanner.'
                : 'Search by MPN, or scan the QR code on a reel or bag label.',
            textAlign: TextAlign.center,
            style: AppText.subheadline.copyWith(color: secondary),
          ),
          const SizedBox(height: 20),
          Text(
            '${catalog.count} rows · ${catalog.mpnCount} MPNs · ${catalog.fields.length} fields',
            style: AppText.footnote.copyWith(color: secondary, fontFeatures: const [FontFeature.tabularFigures()]),
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
          Icon(CupertinoIcons.search, size: 56, color: context.resolve(CupertinoColors.tertiaryLabel)),
          const SizedBox(height: 16),
          Text('No Results for “$query”', style: AppText.title3, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
            'Check the spelling or try part of the MPN.',
            textAlign: TextAlign.center,
            style: AppText.subheadline.copyWith(color: context.resolve(CupertinoColors.secondaryLabel)),
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
          const IconTile(icon: CupertinoIcons.tray_arrow_down_fill, color: CupertinoColors.systemBlue, size: 84),
          const SizedBox(height: 24),
          const Text('No Components', style: AppText.title1),
          const SizedBox(height: 8),
          Text(
            'Import an Excel file. Each column becomes a field you can search and scan against.',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: context.resolve(CupertinoColors.secondaryLabel)),
          ),
          const SizedBox(height: 28),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                borderRadius: BorderRadius.circular(14),
                onPressed: loading ? null : onImport,
                child: loading
                    ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                    : const Text('Import Excel File', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
