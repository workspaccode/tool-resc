import 'dart:ui';

import 'package:flutter/cupertino.dart';

import '../app/theme.dart';

/// iOS 26 "Liquid Glass" material: blurred, translucent, with a hairline rim.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 28, this.tint, this.padding = EdgeInsets.zero});

  final Widget child;
  final double radius;

  /// Optional solid tint, e.g. the accent for a primary button.
  final Color? tint;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = context.isDark;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: CupertinoColors.white.withValues(alpha: dark ? 0.14 : 0.55), width: 0.6),
    );
    final fill = tint != null
        ? context.resolve(tint!)
        : (dark ? const Color(0xFF2C2C2E) : CupertinoColors.white).withValues(alpha: dark ? 0.55 : 0.62);

    // Soft drop shadow; a tinted button glows in its own color instead.
    final shadow = tint != null
        ? context.resolve(tint!).withValues(alpha: dark ? 0.45 : 0.35)
        : CupertinoColors.black.withValues(alpha: dark ? 0.35 : 0.10);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: shadow, blurRadius: 24, spreadRadius: -6, offset: const Offset(0, 8))],
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: ShapeDecoration(shape: shape, color: fill),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Round glass icon button, as used over the camera view.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.onPressed, this.semanticLabel});

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onPressed,
        child: Glass(
          radius: 22,
          child: SizedBox.square(dimension: 44, child: Icon(icon, size: 20, color: CupertinoColors.white)),
        ),
      ),
    );
  }
}
