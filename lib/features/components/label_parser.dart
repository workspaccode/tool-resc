/// How the MPN was read from the label.
enum LabelSource { text, code }

/// Extracts part information from a scanned component label.
///
/// Printed text (OCR), the primary source: the line starting with `MPN:`
/// (also `Mfr P/N`, `Mfr Part #`, `Manufacturer Part Number`), plus `QTY:`
/// and an LCSC code such as `C141700` when present.
///
/// Codes, used as a fallback:
/// - LCSC QR: `{pbn:...,on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100,...}`
/// - ANSI MH10.8.2 / ECIA DataMatrix (DigiKey, Mouser...): `[)>␞06␝1P<MPN>␝Q100...`
/// - 1D barcode carrying a `1P` data identifier: `1PRC0805FR-07820KL`
/// - Any other code is treated as the MPN itself.
class ScannedLabel {
  const ScannedLabel({
    required this.raw,
    required this.mpn,
    required this.source,
    this.supplierPart,
    this.quantity,
    this.orderNumber,
  });

  final String raw;
  final String mpn;
  final LabelSource source;
  final String? supplierPart;
  final String? quantity;
  final String? orderNumber;

  static final _mpnLine = RegExp(
    r'^(?:MPN|M\s?P\s?N|MFR\.?\s*P\s*/?\s*N|MFG\.?\s*P\s*/?\s*N|(?:MFR|MFG|MANUFACTURER)\.?\s*PART\s*(?:NO\.?|#|NUMBER)?)'
    r'\s*[:：;.,]?\s*(.*)$',
    caseSensitive: false,
  );
  static final _qtyLine = RegExp(r'^QTY\s*[:：;.]?\s*(\d+)', caseSensitive: false);
  static final _lcscCode = RegExp(r'^C\d{3,}$');

  /// Parses OCR lines (top to bottom). Null if there is no MPN line.
  static ScannedLabel? fromText(List<String> lines) {
    String? mpn, qty, lcsc;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (mpn == null) {
        final m = _mpnLine.firstMatch(line);
        if (m != null) {
          // The value may be on the same line or, if the line is just "MPN:", the next one.
          final rest = m.group(1)!.trim();
          mpn = _firstToken(rest.isNotEmpty ? rest : (i + 1 < lines.length ? lines[i + 1] : ''));
        }
      }
      qty ??= _qtyLine.firstMatch(line)?.group(1);
      if (lcsc == null && _lcscCode.hasMatch(line)) lcsc = line;
    }
    if (mpn == null || mpn.length < 3 || !mpn.contains(RegExp(r'[0-9]'))) return null;
    return ScannedLabel(raw: lines.join('\n'), mpn: mpn, source: LabelSource.text, supplierPart: lcsc, quantity: qty);
  }

  /// First word of [text], without trailing punctuation OCR tends to pick up.
  static String? _firstToken(String text) {
    final token = text.trim().split(RegExp(r'\s+')).first;
    final cleaned = token.replaceAll(RegExp(r'[.,;:|]+$'), '');
    return cleaned.isEmpty ? null : cleaned;
  }

  /// Parses the raw value of a QR code, DataMatrix or barcode.
  static ScannedLabel parse(String raw) {
    final text = raw.trim();
    return _parseLcsc(text) ?? _parseEcia(text) ?? ScannedLabel(raw: raw, mpn: text, source: LabelSource.code);
  }

  static ScannedLabel? _parseLcsc(String text) {
    if (!text.startsWith('{') || !text.contains('pm:')) return null;
    final body = text.substring(1, text.endsWith('}') ? text.length - 1 : text.length);
    final fields = <String, String>{};
    for (final part in body.split(',')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      fields[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
    final mpn = fields['pm'];
    if (mpn == null || mpn.isEmpty) return null;
    return ScannedLabel(
      raw: text,
      mpn: mpn,
      source: LabelSource.code,
      supplierPart: fields['pc'],
      quantity: fields['qty'],
      orderNumber: fields['on'],
    );
  }

  static ScannedLabel? _parseEcia(String text) {
    // Group separator (0x1D) splits fields; some scanners turn it into other chars.
    final parts = text.split(RegExp('[\u001d\u001e\u0004]'));
    String? mpn, supplierPart, qty;
    for (final p in parts) {
      if (p.startsWith('1P')) {
        mpn ??= p.substring(2);
      } else if (p.startsWith('P') && !p.startsWith('PO')) {
        supplierPart ??= p.substring(1);
      } else if (p.startsWith('Q')) {
        qty ??= p.substring(1);
      }
    }
    if (mpn == null || mpn.isEmpty) return null;
    return ScannedLabel(raw: text, mpn: mpn, source: LabelSource.code, supplierPart: supplierPart, quantity: qty);
  }
}
