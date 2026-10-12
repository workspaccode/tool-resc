import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/features/components/keyboard_scanner.dart';
import 'package:tool_resc/features/components/label_parser.dart';

Duration ms(int n) => Duration(milliseconds: n);

/// Feeds [text] one char every [gap] ms starting at [start]; returns end time.
Duration type(ScanBurstDetector d, String text, {required int gap, int start = 0}) {
  var t = start;
  for (final c in text.split('')) {
    d.addChar(c, ms(t));
    t += gap;
  }
  return ms(t);
}

void main() {
  group('ScanBurstDetector', () {
    test('a fast burst ending in Enter is a scan', () {
      final d = ScanBurstDetector();
      final end = type(d, 'RC0805FR-07820KL', gap: 8);
      expect(d.finish(end), 'RC0805FR-07820KL');
    });

    test('human typing is not a scan', () {
      final d = ScanBurstDetector();
      final end = type(d, 'RC0805', gap: 140);
      expect(d.finish(end), isNull);
    });

    test('a pause before the burst starts a new one', () {
      final d = ScanBurstDetector();
      type(d, 'abc', gap: 150); // someone typed in the search field
      final end = type(d, '{pm:LM358DR,qty:5}', gap: 10, start: 2000);
      expect(d.finish(end), '{pm:LM358DR,qty:5}');
    });

    test('too short bursts are ignored', () {
      final d = ScanBurstDetector();
      expect(d.finish(type(d, 'ab', gap: 5)), isNull);
    });

    test('a full LCSC QR payload parses to the MPN', () {
      final d = ScanBurstDetector();
      const qr = '{pbn:PICK2609230751,on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100,mc:,cc:1}';
      final text = d.finish(type(d, qr, gap: 6))!;
      expect(ScannedLabel.parse(text).mpn, 'RC0805FR-07820KL');
    });
  });

  group('usLayoutChar', () {
    test('decodes by physical key, independent of the OS layout', () {
      // On an Arabic layout these keys type Arabic letters; scanners mean US.
      expect(usLayoutChar(PhysicalKeyboardKey.keyR, shift: true), 'R');
      expect(usLayoutChar(PhysicalKeyboardKey.keyC, shift: false), 'c');
      expect(usLayoutChar(PhysicalKeyboardKey.digit0, shift: false), '0');
      expect(usLayoutChar(PhysicalKeyboardKey.minus, shift: false), '-');
      expect(usLayoutChar(PhysicalKeyboardKey.semicolon, shift: true), ':');
      expect(usLayoutChar(PhysicalKeyboardKey.bracketLeft, shift: true), '{');
      expect(usLayoutChar(PhysicalKeyboardKey.comma, shift: false), ',');
    });

    test('ignores non-character keys', () {
      expect(usLayoutChar(PhysicalKeyboardKey.shiftLeft, shift: false), isNull);
      expect(usLayoutChar(PhysicalKeyboardKey.enter, shift: false), isNull);
    });
  });
}
