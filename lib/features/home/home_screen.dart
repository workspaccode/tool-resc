import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/icon_tile.dart';
import '../components/components_providers.dart';
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
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final WidgetBuilder builder;

  /// Optional live detail shown on the row, e.g. an item count.
  final String? Function(WidgetRef ref)? status;
}

/// Available tools. New features are added here.
final tools = <Tool>[
  Tool(
    title: 'Components',
    subtitle: 'Search by MPN or scan a label',
    icon: CupertinoIcons.cube_box_fill,
    color: CupertinoColors.systemBlue,
    builder: (_) => const ComponentsScreen(),
    status: (ref) {
      final count = ref.watch(catalogProvider).count;
      return count == 0 ? null : '$count';
    },
  ),
];

/// Lets the user choose the current tool.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  CupertinoListTile(
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
