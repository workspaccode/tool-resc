import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../app/settings.dart';
import '../../app/theme.dart';
import '../../widgets/glass.dart';
import 'components_providers.dart';
import 'components_repository.dart';
import 'label_parser.dart';

/// Full-screen camera that reads a label by the user's chosen [ScanMethod]:
/// the printed `MPN:` line (OCR) or the QR code. Pops with the [ScannedLabel].
class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> with WidgetsBindingObserver {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.qrCode, BarcodeFormat.dataMatrix]);

  CameraController? _camera;
  String? _error;
  bool _busy = false;
  bool _done = false;
  bool _torch = false;

  /// The MPN read in the latest frames, and how many frames in a row agreed.
  String? _candidateKey;
  String? _candidateMpn;
  int _agreeing = 0;

  Offset? _focusIndicator;
  Timer? _focusTimer;

  /// Identical reads required before accepting: fewer when the MPN is known.
  static const _readsWhenKnown = 2;
  static const _readsWhenUnknown = 4;

  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _camera?.dispose();
    _textRecognizer.close();
    _barcodeScanner.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera in the background and reopen it on return.
    if (state == AppLifecycleState.inactive) {
      final camera = _camera;
      _camera = null;
      if (mounted) setState(() {});
      camera?.dispose();
    } else if (state == AppLifecycleState.resumed && _camera == null && !_done) {
      _startCamera();
    }
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back).firstOrNull ?? cameras.firstOrNull;
      if (back == null) throw CameraException('NoCamera', 'No camera found on this device.');

      final camera = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      await camera.startImageStream(_onFrame);
      setState(() {
        _camera = camera;
        _torch = false;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code);
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _done) return;
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return;

      switch (ref.read(scanMethodProvider)) {
        case ScanMethod.text:
          final text = await _textRecognizer.processImage(input);
          final lines = [for (final block in text.blocks) ...block.lines.map((l) => l.text)];
          if (ScannedLabel.fromText(lines) case final label?) _consider(label);
        case ScanMethod.code:
          final codes = await _barcodeScanner.processImage(input);
          final raw = codes.map((c) => c.rawValue).nonNulls.where((v) => v.trim().isNotEmpty).firstOrNull;
          if (raw != null) _finish(ScannedLabel.parse(raw));
      }
    } catch (_) {
      // A dropped frame is fine; the next one is processed normally.
    } finally {
      _busy = false;
    }
  }

  void _setMethod(ScanMethod method) {
    HapticFeedback.selectionClick();
    ref.read(scanMethodProvider.notifier).set(method);
    setState(() {
      _candidateKey = null;
      _candidateMpn = null;
      _agreeing = 0;
    });
  }

  /// Accepts an OCR read once enough consecutive frames agree on it.
  void _consider(ScannedLabel label) {
    final repo = ref.read(componentsRepositoryProvider);
    final known = repo.matchKey(label.mpn);
    final key = known ?? mpnKey(label.mpn);

    if (key == _candidateKey) {
      _agreeing++;
    } else {
      _candidateKey = key;
      _agreeing = 1;
    }
    if (mounted) setState(() => _candidateMpn = label.mpn);

    if (_agreeing >= (known != null ? _readsWhenKnown : _readsWhenUnknown)) _finish(label);
  }

  void _finish(ScannedLabel label) {
    if (_done || !mounted) return;
    _done = true;
    HapticFeedback.mediumImpact();
    _camera?.stopImageStream().catchError((_) {});
    Navigator.of(context).pop(label);
  }

  InputImage? _toInputImage(CameraImage image) {
    final camera = _camera;
    if (camera == null) return null;
    final sensor = camera.description.sensorOrientation;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensor);
    } else {
      final device = _orientations[camera.value.deviceOrientation];
      if (device == null) return null;
      rotation = InputImageRotationValue.fromRawValue((sensor - device + 360) % 360);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final expected = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
    if (format != expected || image.planes.length != 1) return null;

    final plane = image.planes.single;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format!,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    final on = !_torch;
    try {
      await camera.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      setState(() => _torch = on);
    } on CameraException catch (_) {
      // No flash on this camera.
    }
  }

  /// Tap to focus, with an iOS-style yellow focus square.
  void _focus(Offset normalized, Offset screen) {
    final camera = _camera;
    if (camera == null) return;
    camera.setFocusPoint(normalized).catchError((_) {});
    camera.setExposurePoint(normalized).catchError((_) {});
    HapticFeedback.selectionClick();
    _focusTimer?.cancel();
    setState(() => _focusIndicator = screen);
    _focusTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusIndicator = null);
    });
  }

  /// The guide frame: a label-shaped rectangle slightly above center.
  static Rect _frame(Size size) {
    final width = min(size.width - 48, 380.0);
    return Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.42), width: width, height: width * 0.62);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final camera = _camera;
    final method = ref.watch(scanMethodProvider);

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final frame = _frame(constraints.biggest);
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_error != null)
                _CameraError(code: _error!)
              else if (camera != null && camera.value.isInitialized)
                _Preview(camera: camera, onTap: _focus)
              else
                const Center(child: CupertinoActivityIndicator(color: CupertinoColors.white, radius: 14)),
              IgnorePointer(child: CustomPaint(painter: _FramePainter(frame))),
              if (_focusIndicator case final p?)
                Positioned(
                  left: p.dx - 36,
                  top: p.dy - 36,
                  child: IgnorePointer(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(border: Border.all(color: CupertinoColors.systemYellow, width: 1.5)),
                    ),
                  ),
                ),
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
                    GlassIconButton(
                      icon: _torch ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt_slash,
                      semanticLabel: 'Flashlight',
                      onPressed: _toggleTorch,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: frame.bottom + 28,
                left: 24,
                right: 24,
                child: Center(
                  child: _StatusPill(method: method, candidate: _candidateMpn),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: padding.bottom + 24,
                child: Center(
                  child: _MethodSwitch(method: method, onChanged: _setMethod),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Camera preview filling the screen (cropped, not letterboxed).
class _Preview extends StatelessWidget {
  const _Preview({required this.camera, required this.onTap});

  final CameraController camera;
  final void Function(Offset normalized, Offset screen) onTap;

  @override
  Widget build(BuildContext context) {
    // previewSize is landscape; the app is portrait.
    final size = camera.value.previewSize!;
    final width = min(size.width, size.height), height = max(size.width, size.height);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: width,
          height: height,
          child: GestureDetector(
            onTapUp: (d) => onTap(Offset(d.localPosition.dx / width, d.localPosition.dy / height), d.globalPosition),
            child: CameraPreview(camera),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.method, required this.candidate});

  final ScanMethod method;
  final String? candidate;

  @override
  Widget build(BuildContext context) {
    final style = AppText.subheadline.copyWith(color: CupertinoColors.white);
    return Glass(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      child: candidate == null
          ? Text(
              method == ScanMethod.text ? 'Point at the “MPN:” line on the label' : 'Point at the QR code on the label',
              style: style.copyWith(fontWeight: FontWeight.w500),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CupertinoActivityIndicator(color: CupertinoColors.white, radius: 8),
                const SizedBox(width: 10),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'MPN  ',
                          style: style.copyWith(color: CupertinoColors.systemGrey2),
                        ),
                        TextSpan(
                          text: candidate,
                          style: style.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
    );
  }
}

/// Glass segmented switch between reading the MPN text and the QR code.
class _MethodSwitch extends StatelessWidget {
  const _MethodSwitch({required this.method, required this.onChanged});

  final ScanMethod method;
  final ValueChanged<ScanMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget segment(IconData icon, String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: CupertinoColors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppText.subheadline.copyWith(color: CupertinoColors.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    return Glass(
      radius: 26,
      padding: const EdgeInsets.all(4),
      child: CupertinoSlidingSegmentedControl<ScanMethod>(
        groupValue: method,
        backgroundColor: const Color(0x00000000),
        thumbColor: CupertinoColors.white.withValues(alpha: 0.28),
        onValueChanged: (m) => onChanged(m!),
        children: {
          ScanMethod.text: segment(CupertinoIcons.textformat, ScanMethod.text.label),
          ScanMethod.code: segment(CupertinoIcons.qrcode, ScanMethod.code.label),
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
    const radius = Radius.circular(24);
    final hole = RRect.fromRectAndRadius(frame, radius);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
      Paint()..color = CupertinoColors.black.withValues(alpha: 0.45),
    );

    final stroke = Paint()
      ..color = CupertinoColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const arm = 34.0, r = 24.0;
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

  final String code;

  @override
  Widget build(BuildContext context) {
    final denied = code.contains('AccessDenied') || code.contains('Restricted');
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
              denied ? 'Allow camera access in Settings to scan component labels.' : code,
              textAlign: TextAlign.center,
              style: AppText.subheadline.copyWith(color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }
}
