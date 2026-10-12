import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../app/theme.dart';
import 'glass.dart';

class ContextMenuAction {
  const ContextMenuAction({required this.label, required this.icon, required this.onPressed, this.destructive = false});

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;
}

/// A small macOS-style menu at [position] (e.g. where the user right-clicked).
Future<void> showContextMenu(
  BuildContext context, {
  required Offset position,
  required List<ContextMenuAction> actions,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: const Color(0x00000000),
      transitionDuration: const Duration(milliseconds: 120),
      reverseTransitionDuration: const Duration(milliseconds: 80),
      pageBuilder: (context, _, _) => _Menu(position: position, actions: actions),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _Menu extends StatelessWidget {
  const _Menu({required this.position, required this.actions});

  static const _width = 220.0;
  static const _itemHeight = 34.0;

  final Offset position;
  final List<ContextMenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = actions.length * _itemHeight + 12;
    // Keep the menu on screen.
    final left = min(position.dx, size.width - _width - 8);
    final top = min(position.dy, size.height - height - 8);
    return Stack(
      children: [
        Positioned.fill(child: GestureDetector(onTap: () => Navigator.pop(context))),
        Positioned(
          left: max(8, left),
          top: max(8, top),
          width: _width,
          child: Glass(
            radius: 12,
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final a in actions) _MenuItem(action: a)],
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({required this.action});

  final ContextMenuAction action;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final color = _hovered
        ? CupertinoColors.white
        : context.resolve(a.destructive ? CupertinoColors.systemRed : CupertinoColors.label);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () {
          Navigator.pop(context);
          a.onPressed();
        },
        child: Container(
          height: _Menu._itemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(7)),
            color: _hovered
                ? context.resolve(a.destructive ? CupertinoColors.systemRed : CupertinoColors.systemBlue)
                : null,
          ),
          child: Row(
            children: [
              Icon(a.icon, size: 16, color: color),
              const SizedBox(width: 10),
              Text(a.label, style: AppText.subheadline.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
