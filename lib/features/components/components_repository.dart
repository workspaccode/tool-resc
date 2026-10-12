import 'package:hive_ce/hive_ce.dart';

class Component {
  const Component({required this.key, required this.mpn, required this.values});

  /// Normalized MPN, the Hive key.
  final String key;
  final String mpn;

  /// Field label -> value, in field order, empty values omitted.
  final Map<String, String> values;
}

class SearchResults {
  const SearchResults({required this.items, required this.total});

  static const empty = SearchResults(items: [], total: 0);

  final List<Component> items;

  /// Total matches; [items] is capped.
  final int total;
}

enum ImportMode { replace, merge }

class ImportResult {
  const ImportResult({required this.inserted, required this.updated, required this.duplicates, required this.skipped});

  final int inserted;

  /// Existing components updated (merge mode).
  final int updated;

  /// Rows whose MPN repeats earlier in the same file; the last one wins.
  final int duplicates;

  /// Rows without a usable MPN.
  final int skipped;
}

/// Normalizes an MPN for matching: uppercase, letters and digits only, so
/// "rc0805fr 07820kl" finds "RC0805FR-07820KL". Empty if nothing is left.
String mpnKey(String mpn) {
  final key = mpn.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return key.length > 255 ? key.substring(0, 255) : key;
}

/// Components stored in Hive. Each Excel header becomes a field; each
/// component is a map of field label -> value keyed by [mpnKey].
class ComponentsRepository {
  ComponentsRepository({required this._meta, required this._items});

  final Box<Object> _meta;
  final LazyBox<Map> _items;

  static const _fieldsKey = 'fields';
  static const _mpnFieldKey = 'mpnField';
  static const _chunk = 2000;

  List<String> get fields => (_meta.get(_fieldsKey) as List?)?.cast<String>() ?? const [];

  String? get mpnField => _meta.get(_mpnFieldKey) as String?;

  int get count => _items.length;

  Future<ImportResult> import({
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) async {
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

    final existing = mode == ImportMode.merge ? _items.keys.cast<String>().toSet() : <String>{};
    final seen = <String>{};
    final pending = <String, Map<String, String>>{};
    var inserted = 0, updated = 0, duplicates = 0, skipped = 0;

    for (final row in rows) {
      final key = mpnKey(row[mpnIndex]);
      if (key.isEmpty) {
        skipped++;
        continue;
      }

      Map<String, String> values;
      if (!seen.add(key)) {
        duplicates++;
        values = pending[key] ?? await _get(key);
      } else if (existing.contains(key)) {
        updated++;
        values = await _get(key);
      } else {
        inserted++;
        values = {};
      }

      // The file's columns overwrite; an empty cell clears that field.
      for (var i = 0; i < labels.length; i++) {
        final v = row[i].trim();
        v.isEmpty ? values.remove(labels[i]) : values[labels[i]] = v;
      }
      pending[key] = values;

      if (pending.length >= _chunk) {
        await _items.putAll(pending);
        pending.clear();
      }
    }
    await _items.putAll(pending);
    await _meta.putAll({_fieldsKey: fields, _mpnFieldKey: labels[mpnIndex]});

    return ImportResult(inserted: inserted, updated: updated, duplicates: duplicates, skipped: skipped);
  }

  /// Searches by MPN: exact match first, then prefix, then contains.
  Future<SearchResults> search(String query, {int limit = 50}) async {
    final key = mpnKey(query);
    if (key.isEmpty) return SearchResults.empty;

    int rank(String k) => k == key ? 0 : (k.startsWith(key) ? 1 : 2);
    final matches = _items.keys.cast<String>().where((k) => k.contains(key)).toList()
      ..sort((a, b) {
        final r = rank(a) - rank(b);
        if (r != 0) return r;
        final l = a.length - b.length;
        return l != 0 ? l : a.compareTo(b);
      });

    final items = await Future.wait(matches.take(limit).map(_component));
    return SearchResults(items: items, total: matches.length);
  }

  Future<void> clear() async {
    await _items.clear();
    await _meta.clear();
  }

  Future<Map<String, String>> _get(String key) async =>
      ((await _items.get(key)) ?? const {}).map((k, v) => MapEntry(k as String, v as String));

  Future<Component> _component(String key) async {
    final raw = await _get(key);
    final values = {for (final f in fields) f: ?raw[f]};
    return Component(key: key, mpn: raw[mpnField] ?? key, values: values);
  }
}
