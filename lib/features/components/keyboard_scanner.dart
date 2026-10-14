import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Detects input from a USB/Bluetooth barcode scanner in keyboard mode.
///
/// A scanner "types" its code much faster than a person and ends with Enter
/// (or Tab). Keys arriving at least [minLength] long with an average gap under
/// [maxAverageGap] form a scan; anything slower is ordinary typing.
class ScanBurstDetector {
  ScanBurstDetector({
    this.minLength = 4,
    this.maxAverageGap = const Duration(milliseconds: 35),
    this.resetGap = const Duration(milliseconds: 120),
  });

  final int minLength;
  final Duration maxAverageGap;

  /// A pause this long starts a new burst.
  final Duration resetGap;

  final _buffer = StringBuffer();
  Duration? _first;
  Duration? _last;
  int _keys = 0;

  void addChar(String char, Duration time) {
    if (_last == null || time - _last! > resetGap) _reset(time);
    _buffer.write(char);
    _keys++;
    _last = time;
  }

  /// Whether the keys so far are clearly a scanner (enough of them, fast).
  bool get inBurst => _keys >= minLength && (_last! - _first!) ~/ (_keys - 1) <= maxAverageGap;

  /// Called on Enter/Tab. Returns the scanned text if the burst was a scan.
  String? finish(Duration time) {
    if (_last != null && time - _last! <= resetGap) return flush();
    _reset(null);
    return null;
  }

  /// Ends the current burst without Enter (for scanners that send no
  /// suffix). Returns the scanned text if it was a scan.
  String? flush() {
    final text = inBurst ? _buffer.toString() : null;
    _reset(null);
    return text;
  }

  void _reset(Duration? time) {
    _buffer.clear();
    _keys = 0;
    _first = time;
    _last = null;
  }
}

/// The character a key produces on a US keyboard layout. Scanners emulate a
/// US keyboard, so decoding by physical key keeps scans correct even when the
/// computer's layout is Arabic, French, etc. Null for non-character keys.
String? usLayoutChar(PhysicalKeyboardKey key, {required bool shift}) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 0x07) return null; // keyboard usage page
  final code = usage & 0xFFFF;
  if (code >= 0x04 && code <= 0x1D) {
    final letter = String.fromCharCode(0x61 + code - 0x04);
    return shift ? letter.toUpperCase() : letter;
  }
  if (code >= 0x1E && code <= 0x27) {
    const plain = '1234567890', shifted = '!@#\$%^&*()';
    return (shift ? shifted : plain)[code - 0x1E];
  }
  // Numeric keypad, which some scanners use for digits.
  if (code >= 0x59 && code <= 0x62) return '1234567890'[code - 0x59];
  const keypad = {0x54: '/', 0x55: '*', 0x56: '-', 0x57: '+', 0x63: '.'};
  if (keypad[code] case final c?) return c;
  const symbols = {
    0x2C: (' ', ' '),
    0x2D: ('-', '_'),
    0x2E: ('=', '+'),
    0x2F: ('[', '{'),
    0x30: (']', '}'),
    0x31: ('\\', '|'),
    0x33: (';', ':'),
    0x34: ("'", '"'),
    0x35: ('`', '~'),
    0x36: (',', '<'),
    0x37: ('.', '>'),
    0x38: ('/', '?'),
  };
  final pair = symbols[code];
  return pair == null ? null : (shift ? pair.$2 : pair.$1);
}

/// Listens for scanner bursts anywhere while [enabled], and reports each
/// scanned text to [onScan]. Normal typing passes through untouched; once
/// input is clearly a scanner, its keys are kept out of any focused text
/// field so a half-typed code doesn't mix with what's there.
class KeyboardScannerListener extends StatefulWidget {
  const KeyboardScannerListener({super.key, required this.onScan, required this.child, this.enabled = true});

  final ValueChanged<String> onScan;
  final bool enabled;
  final Widget child;

  @override
  State<KeyboardScannerListener> createState() => _KeyboardScannerListenerState();
}

class _KeyboardScannerListenerState extends State<KeyboardScannerListener> {
  final _detector = ScanBurstDetector();

  /// Fires when a burst stops without Enter (scanner with no suffix).
  Timer? _idle;
  static const _idleDelay = Duration(milliseconds: 150);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idle?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    // Only while this screen is the visible route (not under a dialog).
    if (!widget.enabled || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event is! KeyDownEvent) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
      _idle?.cancel();
      final text = _detector.finish(event.timeStamp);
      if (text == null) return false;
      widget.onScan(text);
      return true; // the scanner's Enter shouldn't also submit a text field
    }

    final char = usLayoutChar(event.physicalKey, shift: HardwareKeyboard.instance.isShiftPressed);
    if (char == null) return false;
    _detector.addChar(char, event.timeStamp);
    _idle?.cancel();
    _idle = Timer(_idleDelay, () {
      if (!mounted) return;
      final text = _detector.flush();
      if (text != null) widget.onScan(text);
    });
    // Once it's clearly a scanner, keep its keys out of the text field.
    return _detector.inBurst;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
