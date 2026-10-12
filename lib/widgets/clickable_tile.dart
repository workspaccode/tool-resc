import 'package:flutter/cupertino.dart';

/// [CupertinoListTile] that shows a pointer cursor and a hover highlight
/// when used with a mouse (desktop).
class ClickableTile extends StatefulWidget {
  const ClickableTile({
    super.key,
    required this.title,
    this.subtitle,
    this.additionalInfo,
    this.leading,
    this.leadingSize = 28,
    this.trailing,
    this.padding,
    this.selected = false,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? additionalInfo;
  final Widget? leading;
  final double leadingSize;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  /// Highlighted as the current item (e.g. in a split view's list).
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<ClickableTile> createState() => _ClickableTileState();
}

class _ClickableTileState extends State<ClickableTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.selected
        ? CupertinoDynamicColor.resolve(CupertinoColors.systemBlue, context).withValues(alpha: 0.14)
        : _hovered && widget.onTap != null
        ? CupertinoDynamicColor.resolve(CupertinoColors.systemFill, context).withValues(alpha: 0.35)
        : null;

    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: CupertinoListTile(
        title: widget.title,
        subtitle: widget.subtitle,
        additionalInfo: widget.additionalInfo,
        leading: widget.leading,
        leadingSize: widget.leadingSize,
        trailing: widget.trailing,
        padding: widget.padding,
        backgroundColor: background,
        onTap: widget.onTap,
      ),
    );
  }
}
