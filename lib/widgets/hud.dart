import 'package:flutter/cupertino.dart';

import '../app/theme.dart';
import 'glass.dart';

/// Shows a brief iOS-style HUD (e.g. "Copied") in the center of the screen.
void showHud(BuildContext context, {required IconData icon, required String message}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Hud(icon: icon, message: message, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _Hud extends StatefulWidget {
  const _Hud({required this.icon, required this.message, required this.onDone});

  final IconData icon;
  final String message;
  final VoidCallback onDone;

  @override
  State<_Hud> createState() => _HudState();
}

class _HudState extends State<_Hud> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _controller.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    await _controller.reverse();
    widget.onDone();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = context.resolve(CupertinoColors.label);
    return IgnorePointer(
      child: Center(
        child: FadeTransition(
          opacity: _curve,
          child: ScaleTransition(
            scale: Tween(begin: 0.85, end: 1.0).animate(_curve),
            child: Glass(
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 40, color: label),
                  const SizedBox(height: 10),
                  Text(widget.message, style: AppText.headline.copyWith(color: label)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
