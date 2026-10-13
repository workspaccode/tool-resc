import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../widgets/section.dart';
import '../../widgets/hud.dart';
import '../../widgets/clickable_tile.dart';
import '../../widgets/icon_tile.dart';
import 'components_repository.dart';

class ComponentDetailScreen extends StatelessWidget {
  const ComponentDetailScreen({super.key, required this.component, this.mpnField, this.embedded = false});

  final Component component;
  final String? mpnField;

  /// Shown as the detail pane of a split layout rather than a pushed page.
  final bool embedded;

  void _copy(BuildContext context, String value) {
    Clipboard.setData(ClipboardData(text: value));
    HapticFeedback.lightImpact();
    showHud(context, icon: CupertinoIcons.doc_on_doc, message: 'Copied');
  }

  @override
  Widget build(BuildContext context) {
    final fields = component.values.entries.where((e) => e.key != mpnField).toList();
    final secondary = context.resolve(CupertinoColors.secondaryLabel);

    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Component'),
            previousPageTitle: embedded ? null : 'Components',
            automaticallyImplyLeading: !embedded,
            // A second large-title bar in the same route must not animate.
            transitionBetweenRoutes: !embedded,
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => _copy(context, component.mpn),
              child: const Icon(CupertinoIcons.doc_on_doc),
            ),
          ),
          SliverToBoxAdapter(
            child: Section(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _copy(context, component.mpn),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const IconTile(icon: CupertinoIcons.cube_box_fill, color: CupertinoColors.systemBlue, size: 56),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(mpnField ?? 'Search column', style: AppText.footnote.copyWith(color: secondary)),
                              const SizedBox(height: 2),
                              Text(
                                component.mpn,
                                style: AppText.title2.copyWith(fontFeatures: AppText.mpn.fontFeatures),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (fields.isNotEmpty)
            SliverToBoxAdapter(
              child: Section(
                header: '${fields.length} fields',
                footer: isDesktop ? 'Click a field to copy its value.' : 'Tap a field to copy its value.',
                children: [
                  for (final f in fields)
                    ClickableTile(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      title: Text(f.key, style: AppText.footnote.copyWith(color: secondary)),
                      subtitle: Text(
                        f.value,
                        style: AppText.body.copyWith(color: context.resolve(CupertinoColors.label)),
                        maxLines: 6,
                      ),
                      onTap: () => _copy(context, f.value),
                    ),
                ],
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
        ],
      ),
    );
  }
}
