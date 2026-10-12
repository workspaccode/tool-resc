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

  /// Called on Enter/Tab. Returns the scanned text if the burst was a scan.
  String? finish(Duration time) {
    final text = _buffer.toString();
    final keys = _keys;
    final span = (_last ?? time) - (_first ?? time);
    final recent = _last != null && time - _last! <= resetGap;
    _reset(null);
    if (!recent || keys < minLength) return null;
    final averageGap = span ~/ (keys - 1);
    return averageGap <= maxAverageGap ? text : null;
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
/// scanned text to [onScan]. Normal typing passes through untouched.
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

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    // Only while this screen is the visible route (not under a dialog).
    if (!widget.enabled || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (event is! KeyDownEvent) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
      final text = _detector.finish(event.timeStamp);
      if (text == null) return false;
      widget.onScan(text);
      return true; // the scanner's Enter shouldn't also submit a text field
    }

    final char = usLayoutChar(event.physicalKey, shift: HardwareKeyboard.instance.isShiftPressed);
    if (char != null) _detector.addChar(char, event.timeStamp);
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
