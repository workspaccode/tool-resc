import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import 'components_repository.dart';
import 'label_parser.dart';

final componentsRepositoryProvider = Provider<ComponentsRepository>(
  (ref) =>
      ComponentsRepository(meta: Hive.box<Object>(Boxes.componentsMeta), items: Hive.lazyBox<Map>(Boxes.components)),
);

/// Summary of what's in the database.
class Catalog {
  const Catalog({required this.count, required this.fields, required this.mpnField});

  final int count;
  final List<String> fields;
  final String? mpnField;

  bool get isEmpty => count == 0;
}

class CatalogNotifier extends Notifier<Catalog> {
  ComponentsRepository get _repo => ref.read(componentsRepositoryProvider);

  @override
  Catalog build() => _snapshot();

  Catalog _snapshot() {
    final repo = ref.read(componentsRepositoryProvider);
    return Catalog(count: repo.count, fields: repo.fields, mpnField: repo.mpnField);
  }

  Future<ImportResult> import({
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) async {
    final result = await _repo.import(headers: headers, rows: rows, mpnIndex: mpnIndex, mode: mode);
    state = _snapshot();
    return result;
  }

  Future<void> clear() async {
    await _repo.clear();
    ref.read(scannedLabelProvider.notifier).set(null);
    ref.read(searchQueryProvider.notifier).set('');
    state = _snapshot();
  }
}

final catalogProvider = NotifierProvider<CatalogNotifier, Catalog>(CatalogNotifier.new);

class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(SearchQueryNotifier.new);

/// The last scanned label, shown above the results until the query is edited.
class ScannedLabelNotifier extends Notifier<ScannedLabel?> {
  @override
  ScannedLabel? build() => null;

  void set(ScannedLabel? label) => state = label;
}

final scannedLabelProvider = NotifierProvider<ScannedLabelNotifier, ScannedLabel?>(ScannedLabelNotifier.new);

final searchResultsProvider = FutureProvider<SearchResults>((ref) {
  ref.watch(catalogProvider); // re-run after import / clear
  return ref.watch(componentsRepositoryProvider).search(ref.watch(searchQueryProvider));
});
