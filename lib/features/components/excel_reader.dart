import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A sheet read from an Excel file: one header row plus data rows, all as text.
class ExcelTable {
  const ExcelTable({required this.sheetName, required this.headers, required this.rows});

  final String sheetName;
  final List<String> headers;
  final List<List<String>> rows;

  /// Guesses which column holds the MPN from its header, or -1 if none matches.
  int guessMpnColumn() {
    final normalized = headers.map((h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')).toList();
    const exact = [
      'mpn',
      'manufacturerpartnumber',
      'manufacturepartnumber', // LCSC export spelling
      'mfrpartnumber',
      'mfrpart',
      'mfrpn',
      'partnumber',
      'pn',
    ];
    for (final key in exact) {
      final i = normalized.indexOf(key);
      if (i >= 0) return i;
    }
    final partial = RegExp(r'mpn|manufacturer?part|mfrpart');
    return normalized.indexWhere(partial.hasMatch);
  }
}

/// Reads every non-empty sheet of an .xlsx file. Runs in a background isolate
/// so large files don't freeze the UI.
Future<List<ExcelTable>> readExcel(Uint8List bytes) => Isolate.run(() => _XlsxReader(bytes).read());

/// Minimal .xlsx reader (a zip of XML parts). Only extracts cell text; it
/// handles shared/inline strings, numbers, booleans and date-formatted cells.
class _XlsxReader {
  _XlsxReader(Uint8List bytes) : _archive = ZipDecoder().decodeBytes(bytes);

  final Archive _archive;
  late final List<String> _sharedStrings;
  late final List<bool> _dateStyles;

  List<ExcelTable> read() {
    final workbook = _xml('xl/workbook.xml');
    if (workbook == null) throw const FormatException('Not a valid .xlsx file');

    final rels = <String, ({String type, String target})>{};
    for (final r in _xml('xl/_rels/workbook.xml.rels')?.findAllElements('Relationship') ?? <XmlElement>[]) {
      rels[r.getAttribute('Id')!] = (
        type: r.getAttribute('Type')!.split('/').last,
        target: _resolve(r.getAttribute('Target')!),
      );
    }
    String? partOf(String type) => rels.values.where((r) => r.type == type).firstOrNull?.target;

    _sharedStrings = [
      for (final si in _xml(partOf('sharedStrings') ?? 'xl/sharedStrings.xml')?.findAllElements('si') ?? <XmlElement>[])
        _text(si),
    ];
    _dateStyles = _readDateStyles(_xml(partOf('styles') ?? 'xl/styles.xml'));

    final tables = <ExcelTable>[];
    for (final sheet in workbook.findAllElements('sheet')) {
      final relId = sheet.attributes.firstWhere((a) => a.name.local == 'id').value;
      final target = rels[relId]?.target;
      final doc = target == null ? null : _xml(target);
      if (doc == null) continue;
      final table = _toTable(sheet.getAttribute('name') ?? 'Sheet', _readRows(doc));
      if (table != null) tables.add(table);
    }
    return tables;
  }

  XmlDocument? _xml(String path) {
    final file = _archive.findFile(path);
    return file == null ? null : XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  }

  /// Relationship targets are relative to xl/, or absolute from the zip root.
  static String _resolve(String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = ['xl'];
    for (final seg in target.split('/')) {
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (seg != '.' && seg.isNotEmpty) {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  /// Text of a string item, skipping phonetic runs.
  static String _text(XmlElement e) =>
      e.findAllElements('t').where((t) => t.parentElement?.name.local != 'rPh').map((t) => t.innerText).join();

  /// For each cell style index, whether its number format is a date.
  static List<bool> _readDateStyles(XmlDocument? styles) {
    if (styles == null) return const [];
    final custom = <int, String>{
      for (final f in styles.findAllElements('numFmt'))
        int.parse(f.getAttribute('numFmtId')!): f.getAttribute('formatCode') ?? '',
    };
    bool isDate(int id) {
      if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47)) return true;
      final code = custom[id];
      if (code == null) return false;
      final stripped = code.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]|\\.'), '').toLowerCase();
      return stripped.contains(RegExp('[dy]'));
    }

    final cellXfs = styles.findAllElements('cellXfs').firstOrNull;
    return [
      for (final xf in cellXfs?.findElements('xf') ?? <XmlElement>[])
        isDate(int.parse(xf.getAttribute('numFmtId') ?? '0')),
    ];
  }

  List<List<String>> _readRows(XmlDocument doc) {
    final rows = <List<String>>[];
    for (final row in doc.findAllElements('row')) {
      final cells = <String>[];
      for (final c in row.findElements('c')) {
        final ref = c.getAttribute('r');
        final col = ref == null ? cells.length : _columnIndex(ref);
        while (cells.length < col) {
          cells.add('');
        }
        final value = _cellValue(c);
        if (col < cells.length) {
          cells[col] = value;
        } else {
          cells.add(value);
        }
      }
      rows.add(cells);
    }
    return rows;
  }

  static int _columnIndex(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch < 65 || ch > 90) break; // A-Z
      n = n * 26 + (ch - 64);
    }
    return n - 1;
  }

  String _cellValue(XmlElement c) {
    final type = c.getAttribute('t');
    if (type == 'inlineStr') return _text(c.findElements('is').firstOrNull ?? c).trim();
    final v = c.findElements('v').firstOrNull?.innerText;
    if (v == null) return '';
    switch (type) {
      case 's':
        final i = int.tryParse(v);
        return i != null && i < _sharedStrings.length ? _sharedStrings[i].trim() : '';
      case 'b':
        return v == '1' ? 'TRUE' : 'FALSE';
      case 'str' || 'e' || 'd':
        return v.trim();
    }
    final number = double.tryParse(v);
    if (number == null) return v.trim();
    final style = int.tryParse(c.getAttribute('s') ?? '') ?? 0;
    if (style < _dateStyles.length && _dateStyles[style]) return _formatDate(number);
    if (number == number.truncateToDouble() && number.abs() < 1e15) return number.toInt().toString();
    return number.toString();
  }

  static String _formatDate(double serial) {
    final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (serial * 86400000).round()));
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${d.year}-${two(d.month)}-${two(d.day)}';
    return serial == serial.truncateToDouble() ? date : '$date ${two(d.hour)}:${two(d.minute)}';
  }
}

ExcelTable? _toTable(String name, List<List<String>> rows) {
  // Header = first row that has any content.
  final headerIndex = rows.indexWhere((r) => r.any((c) => c.isNotEmpty));
  if (headerIndex < 0) return null;
  final rawHeaders = rows[headerIndex];
  final body = rows.skip(headerIndex + 1).where((r) => r.any((c) => c.isNotEmpty)).toList();
  String cell(List<String> r, int i) => i < r.length ? r[i] : '';

  // Keep columns that have a header or any data.
  final width = rows.fold(0, (w, r) => r.length > w ? r.length : w);
  final keep = [
    for (var i = 0; i < width; i++)
      if (cell(rawHeaders, i).isNotEmpty || body.any((r) => cell(r, i).isNotEmpty)) i,
  ];

  final seen = <String, int>{};
  final headers = <String>[];
  for (final i in keep) {
    var h = cell(rawHeaders, i).isEmpty ? 'Column ${i + 1}' : rawHeaders[i];
    final count = seen.update(h.toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
    if (count > 1) h = '$h ($count)';
    headers.add(h);
  }

  final data = [
    for (final r in body) [for (final i in keep) cell(r, i)],
  ];
  return ExcelTable(sheetName: name, headers: headers, rows: data);
}
