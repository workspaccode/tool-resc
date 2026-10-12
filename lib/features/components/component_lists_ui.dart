import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/prompt.dart';
import 'component_lists.dart';
import 'components_providers.dart';
import 'import_sheet.dart';

Future<void> renameListDialog(BuildContext context, WidgetRef ref, ComponentList list) async {
  final name = await showTextPrompt(context, title: 'Rename List', initialValue: list.name, confirmLabel: 'Rename');
  if (name != null) ref.read(listsProvider.notifier).rename(list.id, name);
}

Future<void> deleteListDialog(BuildContext context, WidgetRef ref, ComponentList list) async {
  final lists = ref.read(listsProvider).lists;
  final rows = ref.read(listRepositoryProvider(list.id)).count;
  final last = lists.length == 1;
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(last ? 'Clear “${list.name}”?' : 'Delete “${list.name}”?'),
      content: Text('Its $rows rows will be removed from this device.'),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(last ? 'Clear' : 'Delete'),
        ),
      ],
    ),
  );
  if (ok == true) await ref.read(listsProvider.notifier).delete(list.id);
}

List<ContextMenuAction> _listActions(BuildContext context, WidgetRef ref, ComponentList list) => [
  ContextMenuAction(
    label: 'Rename…',
    icon: CupertinoIcons.pencil,
    onPressed: () => renameListDialog(context, ref, list),
  ),
  ContextMenuAction(
    label: ref.read(listsProvider).lists.length == 1 ? 'Clear List…' : 'Delete List…',
    icon: CupertinoIcons.trash,
    destructive: true,
    onPressed: () => deleteListDialog(context, ref, list),
  ),
];

/// The component lists nested under "Components" in the desktop sidebar.
/// Click to switch; right-click (or the ⋯ button) to rename or delete.
class ComponentListsSidebar extends ConsumerWidget {
  const ComponentListsSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(listsProvider);
    ref.watch(catalogProvider); // refresh counts after imports
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < state.lists.length; i++)
          _SidebarListItem(
            list: state.lists[i],
            count: ref.read(listRepositoryProvider(state.lists[i].id)).count,
            shortcut: i < 9 ? '${isMacOS ? '⌘' : 'Ctrl+'}${i + 1}' : null,
            selected: state.lists[i].id == state.activeId,
          ),
        _SidebarAddItem(onTap: () => pickAndImportExcel(context)),
      ],
    );
  }
}

class _SidebarListItem extends ConsumerStatefulWidget {
  const _SidebarListItem({required this.list, required this.count, required this.selected, this.shortcut});

  final ComponentList list;
  final int count;
  final bool selected;
  final String? shortcut;

  @override
  ConsumerState<_SidebarListItem> createState() => _SidebarListItemState();
}

class _SidebarListItemState extends ConsumerState<_SidebarListItem> {
  bool _hovered = false;

  void _menu(Offset position) =>
      showContextMenu(context, position: position, actions: _listActions(context, ref, widget.list));

  @override
  Widget build(BuildContext context) {
    final label = context.resolve(CupertinoColors.label);
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final fill = widget.selected
        ? context.resolve(CupertinoColors.systemBlue).withValues(alpha: 0.16)
        : _hovered
        ? context.resolve(CupertinoColors.quaternarySystemFill)
        : null;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => ref.read(listsProvider.notifier).select(widget.list.id),
        onSecondaryTapUp: (d) => _menu(d.globalPosition),
        child: Container(
          height: 32,
          margin: const EdgeInsets.only(left: 22, bottom: 2),
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(8)),
            color: fill,
          ),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.list_bullet,
                size: 15,
                color: widget.selected ? context.resolve(CupertinoColors.systemBlue) : secondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.list.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.subheadline.copyWith(
                    color: label,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (_hovered && widget.shortcut != null)
                Text(widget.shortcut!, style: AppText.caption.copyWith(color: secondary)),
              if (_hovered)
                Builder(
                  builder: (button) => CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(26, 26),
                    onPressed: () {
                      final box = button.findRenderObject()! as RenderBox;
                      _menu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                    },
                    child: Icon(CupertinoIcons.ellipsis_circle, size: 18, color: secondary),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('${widget.count}', style: AppText.footnote.copyWith(color: secondary)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarAddItem extends StatefulWidget {
  const _SidebarAddItem({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_SidebarAddItem> createState() => _SidebarAddItemState();
}

class _SidebarAddItemState extends State<_SidebarAddItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = context.resolve(_hovered ? CupertinoColors.systemBlue : CupertinoColors.secondaryLabel);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 32,
          margin: const EdgeInsets.only(left: 22),
          padding: const EdgeInsets.only(left: 10),
          color: const Color(0x00000000),
          child: Row(
            children: [
              Icon(CupertinoIcons.plus_circle, size: 15, color: color),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Import New List…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.subheadline.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Phone layout: the lists as a scrollable row of chips under the search bar.
/// Long-press a chip to rename or delete it.
class ComponentListChips extends ConsumerWidget {
  const ComponentListChips({super.key, required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(listsProvider);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final l in state.lists)
            _Chip(
              label: l.name,
              selected: l.id == state.activeId,
              onTap: () {
                HapticFeedback.selectionClick();
                ref.read(listsProvider.notifier).select(l.id);
              },
              onLongPress: () => _showListActions(context, ref, l),
            ),
          _Chip(label: 'New List', icon: CupertinoIcons.plus, selected: false, onTap: onImport),
        ],
      ),
    );
  }

  void _showListActions(BuildContext context, WidgetRef ref, ComponentList list) {
    HapticFeedback.mediumImpact();
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(list.name),
        actions: [
          for (final a in _listActions(context, ref, list))
            CupertinoActionSheetAction(
              isDestructiveAction: a.destructive,
              onPressed: () {
                Navigator.pop(sheet);
                a.onPressed();
              },
              child: Text(a.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap, this.onLongPress, this.icon});

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final blue = context.resolve(CupertinoColors.systemBlue);
    final color = selected ? CupertinoColors.white : context.resolve(icon != null ? blue : CupertinoColors.label);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: selected ? blue : context.resolve(CupertinoColors.tertiarySystemFill),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 15, color: color), const SizedBox(width: 4)],
                Text(
                  label,
                  style: AppText.subheadline.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
