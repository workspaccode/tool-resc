import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'component_lists.dart';
import 'components_repository.dart';
import 'label_parser.dart';

/// The active list's repository; switching lists rebuilds everything that
/// depends on it (catalog, search results).
final componentsRepositoryProvider = Provider<ComponentsRepository>(
  (ref) => ref.watch(listRepositoryProvider(ref.watch(listsProvider.select((s) => s.activeId)))),
);

/// Summary of what's in the active list.
class Catalog {
  const Catalog({required this.count, required this.mpnCount, required this.fields, required this.mpnField});

  /// Number of rows.
  final int count;

  /// Number of different MPNs.
  final int mpnCount;
  final List<String> fields;
  final String? mpnField;

  bool get isEmpty => count == 0;
}

class CatalogNotifier extends Notifier<Catalog> {
  ComponentsRepository get _repo => ref.read(componentsRepositoryProvider);

  @override
  Catalog build() {
    ref.watch(componentsRepositoryProvider);
    return _snapshot();
  }

  Catalog _snapshot() {
    final repo = ref.read(componentsRepositoryProvider);
    return Catalog(count: repo.count, mpnCount: repo.mpnCount, fields: repo.fields, mpnField: repo.mpnField);
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
