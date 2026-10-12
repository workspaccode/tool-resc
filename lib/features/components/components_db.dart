import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// A column created from an Excel header. [column] is the SQL column name
/// (c1, c2, ...); [label] is the original header text shown to the user.
class ComponentField {
  const ComponentField({required this.column, required this.label, required this.isMpn});

  final String column;
  final String label;
  final bool isMpn;
}

class Component {
  const Component({required this.id, required this.mpn, required this.values});

  final int id;
  final String mpn;

  /// Field label -> value, in column order.
  final Map<String, String> values;
}

enum ImportMode { replace, merge }

class ImportResult {
  const ImportResult({required this.inserted, required this.updated, required this.skipped});

  final int inserted;
  final int updated;

  /// Rows without an MPN value.
  final int skipped;
}

/// Normalizes an MPN for matching: uppercase, letters and digits only, so
/// "rc0805fr-07820kl" and "RC0805FR 07820KL" both find "RC0805FR-07820KL".
String mpnKey(String mpn) {
  final upper = mpn.trim().toUpperCase();
  final key = upper.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return key.isEmpty ? upper : key;
}

class ComponentsDb {
  ComponentsDb._(this._db);

  final Database _db;

  static ComponentsDb? _instance;

  static Future<ComponentsDb> open() async {
    if (_instance != null) return _instance!;
    final path = p.join(await getDatabasesPath(), 'components.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE component_fields (
            col TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            position INTEGER NOT NULL,
            is_mpn INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE components (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mpn_key TEXT NOT NULL
          )''');
        await db.execute('CREATE INDEX idx_components_mpn ON components(mpn_key)');
      },
    );
    return _instance = ComponentsDb._(db);
  }

  Future<List<ComponentField>> fields() async {
    final rows = await _db.query('component_fields', orderBy: 'position');
    return [
      for (final r in rows)
        ComponentField(column: r['col'] as String, label: r['label'] as String, isMpn: r['is_mpn'] == 1),
    ];
  }

  Future<int> count() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM components')) ?? 0;

  /// Imports rows using [headers] as fields. Headers already known (same label,
  /// case-insensitive) reuse their column; new headers get a new column.
  Future<ImportResult> import({
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) {
    return _db.transaction((txn) async {
      if (mode == ImportMode.replace) await _reset(txn);

      final existing = {
        for (final r in await txn.query('component_fields'))
          (r['label'] as String).toLowerCase(): r['col'] as String,
      };
      var nextIndex = await _nextColumnIndex(txn);
      var position = existing.length;

      // Column name for each header in the file.
      final columns = <String>[];
      for (final header in headers) {
        var col = existing[header.toLowerCase()];
        if (col == null) {
          col = 'c${nextIndex++}';
          await txn.execute('ALTER TABLE components ADD COLUMN $col TEXT');
          await txn.insert('component_fields', {'col': col, 'label': header, 'position': position++});
          existing[header.toLowerCase()] = col;
        }
        columns.add(col);
      }
      await txn.update('component_fields', {'is_mpn': 0});
      await txn.update('component_fields', {'is_mpn': 1}, where: 'col = ?', whereArgs: [columns[mpnIndex]]);

      final knownKeys = mode == ImportMode.merge
          ? {for (final r in await txn.query('components', columns: ['mpn_key'])) r['mpn_key'] as String}
          : <String>{};

      final batch = txn.batch();
      var inserted = 0, updated = 0, skipped = 0;
      for (final row in rows) {
        final mpn = row[mpnIndex].trim();
        if (mpn.isEmpty) {
          skipped++;
          continue;
        }
        final key = mpnKey(mpn);
        final values = <String, Object?>{'mpn_key': key};
        for (var i = 0; i < columns.length; i++) {
          values[columns[i]] = row[i].isEmpty ? null : row[i];
        }

        if (knownKeys.contains(key)) {
          batch.update('components', values, where: 'mpn_key = ?', whereArgs: [key]);
          updated++;
        } else {
          batch.insert('components', values);
          inserted++;
          if (mode == ImportMode.merge) knownKeys.add(key);
        }
      }
      await batch.commit(noResult: true);
      return ImportResult(inserted: inserted, updated: updated, skipped: skipped);
    });
  }

  /// Searches by MPN: exact matches first, then prefix matches, then contains.
  Future<List<Component>> search(String query, {int limit = 50}) async {
    final key = mpnKey(query);
    if (key.isEmpty) return [];
    final rows = await _db.rawQuery(
      '''SELECT * FROM components WHERE mpn_key LIKE ?
         ORDER BY mpn_key = ? DESC, mpn_key LIKE ? DESC, length(mpn_key), mpn_key
         LIMIT ?''',
      ['%$key%', key, '$key%', limit],
    );
    final fields = await this.fields();
    return rows.map((r) => _toComponent(r, fields)).toList();
  }

  Future<void> clear() => _db.transaction(_reset);

  Future<void> _reset(Transaction txn) async {
    await txn.execute('DROP TABLE components');
    await txn.execute('CREATE TABLE components (id INTEGER PRIMARY KEY AUTOINCREMENT, mpn_key TEXT NOT NULL)');
    await txn.execute('CREATE INDEX idx_components_mpn ON components(mpn_key)');
    await txn.delete('component_fields');
  }

  Future<int> _nextColumnIndex(Transaction txn) async {
    final cols = await txn.rawQuery('PRAGMA table_info(components)');
    var highest = 0;
    for (final c in cols) {
      final n = int.tryParse((c['name'] as String).substring(1)) ?? 0;
      highest = max(highest, n);
    }
    return highest + 1;
  }

  Component _toComponent(Map<String, Object?> row, List<ComponentField> fields) {
    final values = <String, String>{};
    var mpn = '';
    for (final f in fields) {
      final v = row[f.column] as String? ?? '';
      values[f.label] = v;
      if (f.isMpn) mpn = v;
    }
    return Component(id: row['id'] as int, mpn: mpn, values: values);
  }
}
