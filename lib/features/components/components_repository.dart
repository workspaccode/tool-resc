import 'package:hive_ce/hive_ce.dart';

class Component {
  const Component({required this.key, required this.mpnKey, required this.mpn, required this.values});

  /// Hive key of this row: `<mpnKey>~<n>`.
  final String key;

  /// Normalized MPN, shared by all rows with the same part.
  final String mpnKey;
  final String mpn;

  /// Field label -> value, in field order, empty values omitted.
  final Map<String, String> values;
}

class SearchResults {
  const SearchResults({required this.items, required this.total});

  static const empty = SearchResults(items: [], total: 0);

  final List<Component> items;

  /// Total matching rows; [items] is capped.
  final int total;
}

enum ImportMode { replace, merge }

class ImportResult {
  const ImportResult({required this.inserted, required this.updated, required this.removed, required this.skipped});

  /// New rows saved.
  final int inserted;

  /// Existing rows updated in place (merge mode).
  final int updated;

  /// Existing rows of an MPN in the file that the file has fewer rows for (merge mode).
  final int removed;

  /// Rows without a usable MPN.
  final int skipped;
}

/// Normalizes an MPN for matching: uppercase, letters and digits only, so
/// "rc0805fr 07820kl" finds "RC0805FR-07820KL". Empty if nothing is left.
String mpnKey(String mpn) {
  final key = mpn.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return key.length > 240 ? key.substring(0, 240) : key; // room for the row suffix
}

/// Folds characters that OCR commonly confuses (O/0, I/1, S/5...) so a
/// misread MPN still matches. Both sides are folded before comparing.
String ocrFold(String key) {
  const map = {'O': '0', 'Q': '0', 'D': '0', 'I': '1', 'L': '1', 'S': '5', 'Z': '2', 'B': '8', 'G': '6'};
  return key.split('').map((c) => map[c] ?? c).join();
}

/// Components stored in Hive. Each Excel header becomes a field and each
/// Excel row is one record (a map of field label -> value). Rows are keyed
/// `<mpnKey>~<n>`, so several rows may share an MPN and searching only
/// needs the keys, which Hive keeps in memory.
class ComponentsRepository {
  ComponentsRepository({required this._meta, required this._items});

  final Box<Object> _meta;
  final LazyBox<Map> _items;

  static const _fieldsKey = 'fields';
  static const _mpnFieldKey = 'mpnField';
  static const _seqKey = 'seq';
  static const _chunk = 2000;

  List<String> get fields => (_meta.get(_fieldsKey) as List?)?.cast<String>() ?? const [];

  String? get mpnField => _meta.get(_mpnFieldKey) as String?;

  /// Number of rows.
  int get count => _items.length;

  /// Number of different MPNs.
  int get mpnCount => _index.length;

  static String _mpnOf(String rowKey) {
    final i = rowKey.lastIndexOf('~');
    return i < 0 ? rowKey : rowKey.substring(0, i);
  }

  /// MPN key -> its row keys, and folded MPN key -> MPN keys. Built on first
  /// use and dropped whenever the data changes.
  Map<String, List<String>>? _byMpn;
  Map<String, List<String>>? _byFolded;

  Map<String, List<String>> get _index {
    if (_byMpn case final index?) return index;
    final index = <String, List<String>>{};
    for (final k in _items.keys.cast<String>()) {
      (index[_mpnOf(k)] ??= []).add(k);
    }
    return _byMpn = index;
  }

  void _invalidate() {
    _byMpn = null;
    _byFolded = null;
  }

  /// The stored MPN key for a scanned MPN, tolerating OCR confusions.
  /// Null if there is no match, or more than one part after folding.
  String? matchKey(String mpn) {
    final key = mpnKey(mpn);
    if (key.isEmpty) return null;
    if (_index.containsKey(key)) return key;
    final hits = (_byFolded ??= _buildFolded())[ocrFold(key)];
    return hits != null && hits.length == 1 ? hits.single : null;
  }

  Map<String, List<String>> _buildFolded() {
    final folded = <String, List<String>>{};
    for (final k in _index.keys) {
      (folded[ocrFold(k)] ??= []).add(k);
    }
    return folded;
  }

  /// All rows of an MPN key, in import order.
  Future<List<Component>> rowsFor(String mpnKey) => Future.wait((_index[mpnKey] ?? const []).map(_component));

  Future<ImportResult> import({
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) async {
    _invalidate();
    if (mode == ImportMode.replace) {
      await _items.clear();
      await _meta.clear();
    }

    // Reuse known fields (case-insensitive), append new ones.
    final fields = [...this.fields];
    final known = {for (final f in fields) f.toLowerCase(): f};
    final labels = <String>[];
    for (final h in headers) {
      final label = known.putIfAbsent(h.toLowerCase(), () {
        fields.add(h);
        return h;
      });
      labels.add(label);
    }

    // Group the file's rows by MPN, keeping file order.
    final groups = <String, List<List<String>>>{};
    var skipped = 0;
    for (final row in rows) {
      final key = mpnKey(row[mpnIndex]);
      if (key.isEmpty) {
        skipped++;
      } else {
        (groups[key] ??= []).add(row);
      }
    }

    // In merge mode, an MPN's existing rows are paired with the file's rows in
    // order: paired rows are updated (fields missing from the file are kept),
    // extra file rows are added, and extra existing rows are removed.
    final existing = mode == ImportMode.merge ? _index : const <String, List<String>>{};
    var seq = (_meta.get(_seqKey) as int?) ?? 0;
    final pending = <String, Map<String, String>>{};
    final toDelete = <String>[];
    var inserted = 0, updated = 0;

    Future<void> flush() async {
      await _items.putAll(pending);
      pending.clear();
    }

    for (final MapEntry(key: mpn, value: fileRows) in groups.entries) {
      final oldKeys = [...?existing[mpn]]..sort(_bySeq);
      for (var i = 0; i < fileRows.length; i++) {
        final Map<String, String> values;
        final String rowKey;
        if (i < oldKeys.length) {
          rowKey = oldKeys[i];
          values = await _get(rowKey);
          updated++;
        } else {
          rowKey = '$mpn~${seq++}';
          values = {};
          inserted++;
        }
        // The file's columns overwrite; an empty cell clears that field.
        for (var c = 0; c < labels.length; c++) {
          final v = fileRows[i][c].trim();
          v.isEmpty ? values.remove(labels[c]) : values[labels[c]] = v;
        }
        pending[rowKey] = values;
        if (pending.length >= _chunk) await flush();
      }
      toDelete.addAll(oldKeys.skip(fileRows.length));
    }
    await flush();
    await _items.deleteAll(toDelete);
    await _meta.putAll({_fieldsKey: fields, _mpnFieldKey: labels[mpnIndex], _seqKey: seq});
    _invalidate();

    return ImportResult(inserted: inserted, updated: updated, removed: toDelete.length, skipped: skipped);
  }

  static int _bySeq(String a, String b) {
    int n(String k) => int.tryParse(k.substring(k.lastIndexOf('~') + 1)) ?? 0;
    return n(a) - n(b);
  }

  /// Searches by MPN: exact match first, then prefix, then contains. Every
  /// row of a matching MPN is returned.
  Future<SearchResults> search(String query, {int limit = 50}) async {
    final key = mpnKey(query);
    if (key.isEmpty) return SearchResults.empty;

    int rank(String k) => k == key ? 0 : (k.startsWith(key) ? 1 : 2);
    final mpns = _index.keys.where((k) => k.contains(key)).toList()
      ..sort((a, b) {
        final r = rank(a) - rank(b);
        if (r != 0) return r;
        final l = a.length - b.length;
        return l != 0 ? l : a.compareTo(b);
      });

    final rowKeys = [for (final m in mpns) ...(_index[m]!..sort(_bySeq))];
    final items = await Future.wait(rowKeys.take(limit).map(_component));
    return SearchResults(items: items, total: rowKeys.length);
  }

  Future<void> clear() async {
    _invalidate();
    await _items.clear();
    await _meta.clear();
  }

  Future<Map<String, String>> _get(String key) async =>
      ((await _items.get(key)) ?? const {}).map((k, v) => MapEntry(k as String, v as String));

  Future<Component> _component(String key) async {
    final raw = await _get(key);
    final values = {for (final f in fields) f: ?raw[f]};
    final mpn = _mpnOf(key);
    return Component(key: key, mpnKey: mpn, mpn: raw[mpnField] ?? mpn, values: values);
  }
}
