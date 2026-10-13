import '../../app/settings.dart';

/// Extracts part information from the code on a component label, read by
/// the camera or a USB scanner:
/// - LCSC QR: `{pbn:...,on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100,...}`
/// - ANSI MH10.8.2 / ECIA DataMatrix (DigiKey, Mouser...): `[)>␞06␝1P<MPN>␝Q100...`
/// - 1D barcode carrying a `1P` data identifier: `1PRC0805FR-07820KL`
/// - Any other code is treated as the MPN itself.
class ScannedLabel {
  const ScannedLabel({required this.raw, required this.mpn, this.supplierPart, this.quantity, this.orderNumber});

  final String raw;
  final String mpn;
  final String? supplierPart;
  final String? quantity;
  final String? orderNumber;

  /// Parses the raw value of a QR code, DataMatrix or barcode.
  static ScannedLabel parse(String raw) {
    final text = raw.trim();
    return _parseLcsc(text) ?? _parseEcia(text) ?? ScannedLabel(raw: raw, mpn: text);
  }

  /// Reads a code the way the user chose in Settings. When [field] isn't in
  /// the code, the whole code is used.
  static ScannedLabel read(String raw, {required CodeReading reading, required String field}) {
    final text = raw.trim();
    switch (reading) {
      case CodeReading.auto:
        return parse(raw);
      case CodeReading.whole:
        return ScannedLabel(raw: raw, mpn: text);
      case CodeReading.field:
        final value = valueOf(text, field);
        // Keep any extras a known format provides (supplier code, quantity).
        final known = _parseLcsc(text) ?? _parseEcia(text);
        return ScannedLabel(
          raw: raw,
          mpn: value ?? text,
          supplierPart: known?.supplierPart,
          quantity: known?.quantity,
          orderNumber: known?.orderNumber,
        );
    }
  }

  /// The value of `field` in codes like `{pm:ABC,qty:5}`, `PN=ABC;LOT=7` or
  /// one `key: value` per line. Case-insensitive; null if absent.
  static String? valueOf(String code, String field) {
    final key = field.trim();
    if (key.isEmpty) return null;
    final match = RegExp(
      '(?:^|[^A-Za-z0-9_])${RegExp.escape(key)}\\s*[:=]\\s*([^,;|}\\]\\r\\n\\t\u001d\u001e]+)',
      caseSensitive: false,
    ).firstMatch(code);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
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
    return ScannedLabel(raw: text, mpn: mpn, supplierPart: supplierPart, quantity: qty);
  }
}
