import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import '../components/component_lists.dart';
import 'sync_api.dart';
import 'sync_controller.dart';
import 'sync_prefs.dart';

/// The projects this device is a member of, cached so they show offline.
/// Projects are shared by code: create one here and give the code to the
/// other devices, or enter a code to join.
class ProjectsController extends Notifier<List<ProjectInfo>> {
  static const _key = 'syncProjects';

  Box<Object> get _box => Hive.box<Object>(Boxes.settings);
  SyncApi get _api => ref.read(syncApiProvider);
  SyncPrefs get _prefs => ref.read(syncPrefsProvider);

  @override
  List<ProjectInfo> build() => [
    for (final m in (_box.get(_key) as List? ?? const []).cast<Map>()) ProjectInfo.fromJson(m),
  ];

  ProjectInfo? byId(String? id) => state.where((p) => p.id == id).firstOrNull;

  Future<ProjectInfo> create(String name) async {
    final p = await _api.createProject(_prefs, name);
    _set([...state, p]);
    return p;
  }

  /// Joins with a code and downloads the project's lists.
  Future<ProjectInfo> join(String code) async {
    final p = await _api.joinProject(_prefs, code);
    _set([...state.where((x) => x.id != p.id), p]);
    unawaited(ref.read(syncProvider.notifier).syncNow());
    return p;
  }

  /// Leaves the project. Its lists stay on this device as local lists.
  Future<void> leave(String id) async {
    await _api.leaveProject(_prefs, id);
    _forget({id});
  }

  /// Reloads the device's projects from the server.
  Future<void> refresh() async {
    final projects = await _api.myProjects(_prefs);
    final gone = {for (final p in state) p.id}.difference({for (final p in projects) p.id});
    _set(projects);
    _forget(gone);
  }

  void _forget(Set<String> ids) {
    if (ids.isEmpty) return;
    _set(state.where((p) => !ids.contains(p.id)).toList());
    final lists = ref.read(listsProvider.notifier);
    for (final l in ref.read(listsProvider).lists) {
      if (ids.contains(l.projectId)) lists.share(l.id, null);
    }
  }

  void _set(List<ProjectInfo> projects) {
    _box.put(_key, [for (final p in projects) p.toJson()]);
    state = projects;
  }
}

final projectsProvider = NotifierProvider<ProjectsController, List<ProjectInfo>>(ProjectsController.new);
