import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/settings.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/components/label_parser.dart';

void main() {
  group('ScannedLabel', () {
    test('parses LCSC QR', () {
      final label = ScannedLabel.parse(
        '{pbn:PICK2609230751,on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100,mc:,cc:1,pdi:123,hp:null}',
      );
      expect(label.mpn, 'RC0805FR-07820KL');
      expect(label.supplierPart, 'C141700');
      expect(label.quantity, '100');
      expect(label.orderNumber, 'WM2609230751');
    });

    test('parses ECIA DataMatrix', () {
      final label = ScannedLabel.parse('[)>\u001e06\u001dP296-1234-ND\u001d1PRC0805FR-07820KL\u001dQ100\u001e\u0004');
      expect(label.mpn, 'RC0805FR-07820KL');
      expect(label.supplierPart, '296-1234-ND');
      expect(label.quantity, '100');
    });

    test('parses 1P barcode and plain text', () {
      expect(ScannedLabel.parse('1PRC0805FR-07820KL').mpn, 'RC0805FR-07820KL');
      expect(ScannedLabel.parse(' RC0805FR-07820KL ').mpn, 'RC0805FR-07820KL');
    });
  });

  group('ScannedLabel.read (Settings › Read scanned code)', () {
    const lcsc = '{pbn:PICK1,on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100}';

    test('auto-detect recognizes known formats, else uses the whole code', () {
      expect(ScannedLabel.read(lcsc, reading: CodeReading.auto, field: 'pm').mpn, 'RC0805FR-07820KL');
      expect(ScannedLabel.read('INTERNAL-42', reading: CodeReading.auto, field: 'pm').mpn, 'INTERNAL-42');
    });

    test('whole code is searched as is', () {
      expect(ScannedLabel.read(lcsc, reading: CodeReading.whole, field: 'pm').mpn, lcsc);
    });

    test('a named field is taken from any key/value code', () {
      ScannedLabel read(String code, String field) => ScannedLabel.read(code, reading: CodeReading.field, field: field);
      expect(read(lcsc, 'pc').mpn, 'C141700');
      expect(read(lcsc, 'pc').quantity, '100'); // extras of a known format are kept
      expect(read('PN=ABC-123;LOT=7', 'pn').mpn, 'ABC-123');
      expect(read('Part: XYZ 9\nLot: 4', 'part').mpn, 'XYZ 9');
      expect(read('{pbn:PICK1,pm:R1}', 'pm').mpn, 'R1'); // "pbn" isn't mistaken for "pm"
      expect(read('NO-FIELDS-HERE', 'pn').mpn, 'NO-FIELDS-HERE'); // falls back to the whole code
    });
  });

  test('mpnKey ignores case, spaces and dashes', () {
    expect(mpnKey('rc0805fr 07820kl'), mpnKey('RC0805FR-07820KL'));
  });
}
