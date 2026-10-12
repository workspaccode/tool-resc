import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/theme.dart';
import '../../widgets/glass.dart';

/// Full-screen camera that pops with the raw text of the first code inside
/// the frame.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes.map((b) => b.rawValue).nonNulls.where((v) => v.trim().isNotEmpty).firstOrNull;
    if (value == null) return;
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(value);
  }

  /// The scan frame: a square slightly above center.
  static Rect _frame(Size size) {
    final side = min(size.width * 0.72, 320.0);
    final center = Offset(size.width / 2, size.height * 0.44);
    return Rect.fromCenter(center: center, width: side, height: side);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final frame = _frame(constraints.biggest);
          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                scanWindow: frame,
                onDetect: _onDetect,
                errorBuilder: (context, error) => _CameraError(code: error.errorCode),
              ),
              IgnorePointer(child: CustomPaint(painter: _FramePainter(frame))),
              Positioned(
                top: padding.top + 8,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: CupertinoIcons.xmark,
                      semanticLabel: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    ValueListenableBuilder(
                      valueListenable: _controller,
                      builder: (context, state, _) => GlassIconButton(
                        icon: state.torchState == TorchState.on ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt_slash,
                        semanticLabel: 'Flashlight',
                        onPressed: _controller.toggleTorch,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: frame.bottom + 28,
                left: 0,
                right: 0,
                child: Center(
                  child: Glass(
                    radius: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    child: Text(
                      'Point at the QR code on the label',
                      style: AppText.subheadline.copyWith(color: CupertinoColors.white, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Dims everything outside the frame and draws iOS-style corner brackets.
class _FramePainter extends CustomPainter {
  _FramePainter(this.frame);

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(28);
    final hole = RRect.fromRectAndRadius(frame, radius);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
      Paint()..color = CupertinoColors.black.withValues(alpha: 0.5),
    );

    final stroke = Paint()
      ..color = CupertinoColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const arm = 34.0, r = 28.0;
    final l = frame.left, t = frame.top, rt = frame.right, b = frame.bottom;
    for (final path in [
      Path()
        ..moveTo(l, t + arm)
        ..lineTo(l, t + r)
        ..arcToPoint(Offset(l + r, t), radius: radius)
        ..lineTo(l + arm, t),
      Path()
        ..moveTo(rt - arm, t)
        ..lineTo(rt - r, t)
        ..arcToPoint(Offset(rt, t + r), radius: radius)
        ..lineTo(rt, t + arm),
      Path()
        ..moveTo(rt, b - arm)
        ..lineTo(rt, b - r)
        ..arcToPoint(Offset(rt - r, b), radius: radius)
        ..lineTo(rt - arm, b),
      Path()
        ..moveTo(l + arm, b)
        ..lineTo(l + r, b)
        ..arcToPoint(Offset(l, b - r), radius: radius)
        ..lineTo(l, b - arm),
    ]) {
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.frame != frame;
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.code});

  final MobileScannerErrorCode code;

  @override
  Widget build(BuildContext context) {
    final denied = code == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.camera, size: 48, color: CupertinoColors.systemGrey),
            const SizedBox(height: 16),
            Text(
              denied ? 'Camera Access Needed' : 'Camera Unavailable',
              style: AppText.title3.copyWith(color: CupertinoColors.white),
            ),
            const SizedBox(height: 8),
            Text(
              denied ? 'Allow camera access in Settings to scan component labels.' : code.name,
              textAlign: TextAlign.center,
              style: AppText.subheadline.copyWith(color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }
}
