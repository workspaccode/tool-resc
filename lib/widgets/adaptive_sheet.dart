import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../app/platform.dart';
import '../app/theme.dart';

/// A bottom sheet on phones; a centered panel (like a macOS sheet) on wide
/// screens. [builder] gets the scroll controller for its main scroll view.
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController controller) builder,
}) {
  if (MediaQuery.sizeOf(context).width < kWideLayout) {
    return showCupertinoSheet<T>(context: context, scrollableBuilder: builder);
  }
  return Navigator.of(context, rootNavigator: true).push<T>(
    CupertinoDialogRoute<T>(
      context: context,
      barrierDismissible: true,
      barrierColor: const Color(0x66000000),
      builder: (context) => _Panel(builder: builder),
    ),
  );
}

class _Panel extends StatefulWidget {
  const _Panel({required this.builder});

  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Hairline rim so the panel reads as a window in both themes.
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
        color: (context.isDark ? CupertinoColors.white : CupertinoColors.black).withValues(alpha: 0.12),
        width: 0.5,
      ),
    );
    return Center(
      child: SizedBox(
        width: min(600, size.width - 80),
        height: min(760, size.height - 80),
        // Shadow behind the panel; the hairline rim is drawn on top of it.
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withValues(alpha: context.isDark ? 0.5 : 0.22),
                blurRadius: 40,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(shape: shape),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(18),
              // The panel is not full screen: drop the window's safe-area insets.
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                removeBottom: true,
                // Elevated level: system colors use their lighter "raised"
                // variants in dark mode, like an iOS sheet.
                child: CupertinoUserInterfaceLevel(
                  data: CupertinoUserInterfaceLevelData.elevated,
                  child: widget.builder(context, _controller),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
