import 'package:flutter_test/flutter_test.dart';
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

  group('ScannedLabel.fromText (OCR)', () {
    // Lines as ML Kit reads the LCSC bag label.
    const label = [
      '3435-B-A10-016 LCSC.COM',
      'C141700',
      'QTY: 100',
      'MPN:RC0805FR-07820KL',
      '125mW 820kΩ 150V Thick Film Res',
      'istor ±100ppm/°C ±1% 0805 Chip R',
      'D/C:25+ COO:CN',
    ];

    test('reads the MPN line, quantity and LCSC code', () {
      final l = ScannedLabel.fromText(label)!;
      expect(l.mpn, 'RC0805FR-07820KL');
      expect(l.source, LabelSource.text);
      expect(l.quantity, '100');
      expect(l.supplierPart, 'C141700');
    });

    test('tolerates OCR spacing and separators', () {
      for (final line in ['MPN: RC0805FR-07820KL', 'MPN ; RC0805FR-07820KL', 'mpn:RC0805FR-07820KL.', 'M PN:RC0805FR-07820KL']) {
        expect(ScannedLabel.fromText([line])?.mpn, 'RC0805FR-07820KL', reason: line);
      }
    });

    test('takes the value from the next line when the MPN line is bare', () {
      expect(ScannedLabel.fromText(['MPN:', 'RC0805FR-07820KL'])?.mpn, 'RC0805FR-07820KL');
    });

    test('supports other supplier wordings', () {
      expect(ScannedLabel.fromText(['Mfr P/N: LM358DR'])?.mpn, 'LM358DR');
      expect(ScannedLabel.fromText(['Manufacturer Part Number: TPS7A0533PDBVR'])?.mpn, 'TPS7A0533PDBVR');
    });

    test('ignores text without an MPN line', () {
      expect(ScannedLabel.fromText(['QTY: 100', 'C141700', 'D/C:25+']), isNull);
      expect(ScannedLabel.fromText(['MPN: N/A']), isNull);
    });
  });

  test('ocrFold matches common misreads', () {
    expect(ocrFold(mpnKey('RCO805FR-0782OKL')), ocrFold(mpnKey('RC0805FR-07820KL')));
    expect(ocrFold('L M358DR'.replaceAll(' ', '')), ocrFold('1M358DR'));
  });

  test('mpnKey ignores case, spaces and dashes', () {
    expect(mpnKey('rc0805fr 07820kl'), mpnKey('RC0805FR-07820KL'));
  });
}
