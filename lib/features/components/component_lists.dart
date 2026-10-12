import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import 'components_repository.dart';

/// A named set of imported components (e.g. one order, BOM or customer).
class ComponentList {
  const ComponentList({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, String> toMap() => {'id': id, 'name': name};
}

class ListsState {
  const ListsState({required this.lists, required this.activeId});

  final List<ComponentList> lists;
  final String activeId;

  ComponentList get active => lists.firstWhere((l) => l.id == activeId, orElse: () => lists.first);
}

/// The registry of component lists and which one is active. Each list's data
/// lives in its own Hive boxes, opened at startup or when created.
class ListsNotifier extends Notifier<ListsState> {
  Box<Object> get _settings => Hive.box<Object>(Boxes.settings);

  @override
  ListsState build() {
    final lists = [
      for (final m in (_settings.get(ListKeys.lists)! as List).cast<Map>())
        ComponentList(id: m['id'] as String, name: m['name'] as String),
    ];
    final active = _settings.get(ListKeys.active) as String?;
    return ListsState(lists: lists, activeId: lists.any((l) => l.id == active) ? active! : lists.first.id);
  }

  void _save(ListsState next) {
    _settings.putAll({
      ListKeys.lists: [for (final l in next.lists) l.toMap()],
      ListKeys.active: next.activeId,
    });
    state = next;
  }

  void select(String id) {
    if (id != state.activeId) _save(ListsState(lists: state.lists, activeId: id));
  }

  /// Creates an empty list, makes it active, and returns its id.
  Future<String> create(String name) async {
    final id = 'l${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await openListBoxes(id);
    _save(
      ListsState(
        lists: [
          ...state.lists,
          ComponentList(id: id, name: _uniqueName(name)),
        ],
        activeId: id,
      ),
    );
    return id;
  }

  void rename(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _save(
      ListsState(
        lists: [for (final l in state.lists) l.id == id ? ComponentList(id: id, name: trimmed) : l],
        activeId: state.activeId,
      ),
    );
  }

  /// Deletes a list and its data. The last list is emptied instead, so there
  /// is always one.
  Future<void> delete(String id) async {
    if (state.lists.length == 1) {
      await ref.read(listRepositoryProvider(id)).clear();
      ref.invalidate(listRepositoryProvider(id));
      return;
    }
    final remaining = state.lists.where((l) => l.id != id).toList();
    _save(ListsState(lists: remaining, activeId: id == state.activeId ? remaining.first.id : state.activeId));
    await deleteListBoxes(id);
    ref.invalidate(listRepositoryProvider(id));
  }

  /// Lists other than the active one that contain [mpn].
  List<ComponentList> othersContaining(String mpn) => [
    for (final l in state.lists)
      if (l.id != state.activeId && ref.read(listRepositoryProvider(l.id)).matchKey(mpn) != null) l,
  ];

  String _uniqueName(String name) {
    final base = name.trim().isEmpty ? 'New List' : name.trim();
    final taken = {for (final l in state.lists) l.name.toLowerCase()};
    if (!taken.contains(base.toLowerCase())) return base;
    var n = 2;
    while (taken.contains('$base $n'.toLowerCase())) {
      n++;
    }
    return '$base $n';
  }
}

final listsProvider = NotifierProvider<ListsNotifier, ListsState>(ListsNotifier.new);

/// One repository per list, kept so each list's key index stays cached.
final listRepositoryProvider = Provider.family<ComponentsRepository, String>(
  (ref, id) => ComponentsRepository(
    meta: Hive.box<Object>(Boxes.componentsMeta(id)),
    items: Hive.lazyBox<Map>(Boxes.components(id)),
  ),
);
