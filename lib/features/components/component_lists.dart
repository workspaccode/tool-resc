import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import 'components_repository.dart';

/// A named set of imported components (e.g. one order, BOM or customer).
class ComponentList {
  const ComponentList({required this.id, required this.name, this.projectId, this.remoteId, this.remoteVersion});

  factory ComponentList.fromMap(Map m) => ComponentList(
    id: m['id'] as String,
    name: m['name'] as String,
    projectId: m['projectId'] as String?,
    remoteId: m['remoteId'] as String?,
    remoteVersion: m['remoteVersion'] as int?,
  );

  final String id;
  final String name;

  /// Server Sync: the project this list is shared in, and its id there.
  /// Null for lists that stay on this device.
  final String? projectId;
  final String? remoteId;

  /// The server's data version this device has (null until confirmed).
  final int? remoteVersion;

  bool get isShared => projectId != null && remoteId != null;

  ComponentList copyWith({String? name, int? remoteVersion}) => ComponentList(
    id: id,
    name: name ?? this.name,
    projectId: projectId,
    remoteId: remoteId,
    remoteVersion: remoteVersion ?? this.remoteVersion,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'name': name,
    'projectId': ?projectId,
    'remoteId': ?remoteId,
    'remoteVersion': ?remoteVersion,
  };
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
    final lists = [for (final m in (_settings.get(ListKeys.lists)! as List).cast<Map>()) ComponentList.fromMap(m)];
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
        lists: [for (final l in state.lists) l.id == id ? l.copyWith(name: trimmed) : l],
        activeId: state.activeId,
      ),
    );
  }

  /// Deletes a list and its data. The last list is emptied instead, so there
  /// is always one. (Removing a shared list from its project is up to the
  /// caller, see SyncController.recordDelete.)
  Future<void> delete(String id) async {
    if (state.lists.length == 1) {
      await ref.read(listRepositoryProvider(id)).clear();
      ref.invalidate(listRepositoryProvider(id));
      share(id, null); // an emptied list is no longer in its project
      return;
    }
    final remaining = state.lists.where((l) => l.id != id).toList();
    _save(ListsState(lists: remaining, activeId: id == state.activeId ? remaining.first.id : state.activeId));
    await deleteListBoxes(id);
    ref.invalidate(listRepositoryProvider(id));
  }

  /// Shares a list in a project (or, with null, keeps it on this device
  /// only). Returns the list's id on the server.
  String? share(String id, String? projectId, {String? remoteId}) {
    String? shared;
    _save(
      ListsState(
        lists: [
          for (final l in state.lists)
            if (l.id == id)
              ComponentList(
                id: l.id,
                name: l.name,
                projectId: projectId,
                remoteId: shared = projectId == null ? null : (remoteId ?? l.remoteId ?? newRemoteId()),
              )
            else
              l,
        ],
        activeId: state.activeId,
      ),
    );
    return shared;
  }

  void setRemoteVersion(String id, int version) {
    if (!state.lists.any((l) => l.id == id && l.remoteVersion != version)) return;
    _save(
      ListsState(
        lists: [for (final l in state.lists) l.id == id ? l.copyWith(remoteVersion: version) : l],
        activeId: state.activeId,
      ),
    );
  }

  /// Adds a list that came from a project, without making it active.
  Future<String> addShared({required String name, required String projectId, required String remoteId}) async {
    final id = 'l${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await openListBoxes(id);
    _save(
      ListsState(
        lists: [
          ...state.lists,
          ComponentList(id: id, name: name, projectId: projectId, remoteId: remoteId),
        ],
        activeId: state.activeId,
      ),
    );
    return id;
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

/// A random id for a list shared to a project, unique across devices (every
/// device's first list is called "default" locally).
String newRemoteId() {
  final r = Random.secure();
  return [for (var i = 0; i < 12; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

final listsProvider = NotifierProvider<ListsNotifier, ListsState>(ListsNotifier.new);

/// One repository per list, kept so each list's key index stays cached.
final listRepositoryProvider = Provider.family<ComponentsRepository, String>(
  (ref, id) => ComponentsRepository(
    meta: Hive.box<Object>(Boxes.componentsMeta(id)),
    items: Hive.lazyBox<Map>(Boxes.components(id)),
  ),
);
