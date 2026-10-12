import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/clickable_tile.dart';
import '../../widgets/icon_tile.dart';
import '../components/components_providers.dart';
import '../components/component_lists_ui.dart';
import '../components/components_screen.dart';
import 'settings_sheet.dart';

class Tool {
  const Tool({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.builder,
    this.status,
    this.sidebarSection,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final WidgetBuilder builder;

  /// Optional live detail shown on the row, e.g. an item count.
  final String? Function(WidgetRef ref)? status;

  /// Extra sidebar items shown under the tool while it's open (wide layout).
  final WidgetBuilder? sidebarSection;
}

/// Available tools. New features are added here.
final tools = <Tool>[
  Tool(
    title: 'Components',
    subtitle: 'Search by MPN or scan a label',
    icon: CupertinoIcons.cube_box_fill,
    color: CupertinoColors.systemBlue,
    builder: (_) => const ComponentsScreen(),
    sidebarSection: (_) => const ComponentListsSidebar(),
    status: (ref) {
      final count = ref.watch(catalogProvider).count;
      return count == 0 ? null : '$count';
    },
  ),
];

/// Lets the user choose the current tool: a list on phones, a sidebar next
/// to the open tool on wide screens (desktop, tablets).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _current = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < kWideLayout) return _buildList(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(current: _current, onSelect: (i) => setState(() => _current = i)),
            Container(width: 0.5, color: context.resolve(CupertinoColors.separator)),
            Expanded(
              child: KeyedSubtree(key: ValueKey(_current), child: tools[_current].builder(context)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList(BuildContext context) {
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Tools'),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => showSettingsSheet(context),
              child: const Icon(CupertinoIcons.gear_alt, size: 26),
            ),
          ),
          SliverToBoxAdapter(
            child: Section(
              header: 'CHOOSE A TOOL',
              children: [
                for (final tool in tools)
                  ClickableTile(
                    padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 14, 12),
                    leadingSize: 44,
                    leading: IconTile(icon: tool.icon, color: tool.color, size: 44),
                    title: Text(tool.title, style: AppText.headline),
                    subtitle: Text(tool.subtitle),
                    additionalInfo: switch (tool.status?.call(ref)) {
                      final s? => Text(s),
                      null => null,
                    },
                    trailing: const CupertinoListTileChevron(),
                    onTap: () =>
                        Navigator.of(context).push(CupertinoPageRoute(title: tool.title, builder: tool.builder)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// macOS-style source list of tools, with Settings at the bottom.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  static const _background = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFEBEBF0),
    darkColor: Color(0xFF1E1E20),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    return Container(
      width: 250,
      color: context.resolve(_background),
      padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 20, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const IconTile(icon: CupertinoIcons.wrench_fill, color: CupertinoColors.systemIndigo, size: 28),
                const SizedBox(width: 10),
                Text('Tool Resc', style: AppText.headline.copyWith(color: context.resolve(CupertinoColors.label))),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Text(
              'Tools',
              style: AppText.caption.copyWith(color: secondary, fontWeight: FontWeight.w600),
            ),
          ),
          for (var i = 0; i < tools.length; i++) ...[
            _SidebarItem(
              icon: tools[i].icon,
              color: tools[i].color,
              title: tools[i].title,
              badge: tools[i].sidebarSection == null ? tools[i].status?.call(ref) : null,
              selected: i == current,
              onTap: () => onSelect(i),
            ),
            if (i == current && tools[i].sidebarSection != null) tools[i].sidebarSection!(context),
          ],
          const Spacer(),
          _SidebarItem(
            icon: CupertinoIcons.gear_alt_fill,
            color: CupertinoColors.systemGrey,
            title: 'Settings',
            selected: false,
            onTap: () => showSettingsSheet(context),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fill = widget.selected
        ? context.resolve(CupertinoColors.systemFill)
        : _hovered
        ? context.resolve(CupertinoColors.quaternarySystemFill)
        : null;
    final label = context.resolve(CupertinoColors.label);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 38,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(9)),
            color: fill,
          ),
          child: Row(
            children: [
              IconTile(icon: widget.icon, color: widget.color, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  style: AppText.subheadline.copyWith(
                    color: label,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.badge != null)
                Text(
                  widget.badge!,
                  style: AppText.footnote.copyWith(color: context.resolve(CupertinoColors.secondaryLabel)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
