import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/hud.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/prompt.dart';
import '../../widgets/section.dart';
import '../components/component_lists.dart';
import 'projects_controller.dart';
import 'sync_api.dart';
import 'sync_controller.dart';
import 'sync_prefs.dart';

/// Settings › Server Sync › Projects: the projects this device is in, and
/// creating or joining one with a code.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  bool _busy = false;

  ProjectsController get _projects => ref.read(projectsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _projects.refresh().catchError((_) {}); // offline: show the cached ones
  }

  Future<void> _create() async {
    final name = await showTextPrompt(
      context,
      title: 'New Project',
      message: 'A site, customer or job. You’ll get a code to share it with other devices.',
      initialValue: '',
      confirmLabel: 'Create',
    );
    if (name == null) return;
    final p = await _busyWhile(() => _projects.create(name));
    if (p != null && mounted) _open(p, created: true);
  }

  Future<void> _join() async {
    final code = await showTextPrompt(
      context,
      title: 'Join Project',
      message: 'Enter the code shown on a device that is already in the project, e.g. K7F2-QX9M.',
      initialValue: '',
      confirmLabel: 'Join',
    );
    if (code == null) return;
    final p = await _busyWhile(() => _projects.join(code));
    if (p != null && mounted) _open(p);
  }

  void _open(ProjectInfo p, {bool created = false}) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ProjectScreen(projectId: p.id, justCreated: created),
      ),
    );
  }

  Future<T?> _busyWhile<T>(Future<T> Function() action) async {
    setState(() => _busy = true);
    try {
      return await action();
    } catch (e) {
      if (mounted) {
        HapticFeedback.vibrate();
        _alert(
          context,
          e is SyncHttpException && e.status == 404 ? 'Wrong Code' : 'Can’t Connect',
          e is SyncHttpException && e.status == 404 ? 'No project has this code. Check it and try again.' : '$e',
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider);
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final blue = context.resolve(CupertinoColors.systemBlue);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Projects'),
        trailing: _busy ? const CupertinoActivityIndicator() : null,
      ),
      child: SafeArea(
        child: ListView(
          children: [
            Section(
              header: 'My Projects',
              footer:
                  'Each project has a code. Enter it on another phone or computer to share the project’s '
                  'lists with it and see what was scanned.',
              children: [
                if (projects.isEmpty)
                  CupertinoListTile(
                    title: Text('No projects yet', style: TextStyle(color: secondary)),
                  ),
                for (final p in projects)
                  CupertinoListTile(
                    leading: const IconTile(icon: CupertinoIcons.folder_fill, color: CupertinoColors.systemPurple),
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.code} · ${p.lists} ${p.lists == 1 ? 'list' : 'lists'} · '
                      '${p.members} ${p.members == 1 ? 'device' : 'devices'}',
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _open(p),
                  ),
              ],
            ),
            Section(
              children: [
                CupertinoListTile(
                  leading: const IconTile(icon: CupertinoIcons.add, color: CupertinoColors.systemGreen),
                  title: Text('New Project…', style: TextStyle(color: blue)),
                  onTap: _busy ? null : _create,
                ),
                CupertinoListTile(
                  leading: const IconTile(icon: CupertinoIcons.qrcode, color: CupertinoColors.systemBlue),
                  title: Text('Join with Code…', style: TextStyle(color: blue)),
                  onTap: _busy ? null : _join,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One project: its code, devices, lists, and the last scans — so you can
/// see what was taken, and by which device.
class ProjectScreen extends ConsumerStatefulWidget {
  const ProjectScreen({super.key, required this.projectId, this.justCreated = false});

  final String projectId;
  final bool justCreated;

  @override
  ConsumerState<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends ConsumerState<ProjectScreen> {
  static const _page = 50;

  ProjectDetail? _detail;
  List<ScanRecord> _scans = const [];
  int _total = 0;
  int _limit = _page;
  bool _mine = false;
  bool _loading = false;
  String? _error;

  SyncPrefs get _prefs => ref.read(syncPrefsProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(syncApiProvider);
    try {
      await ref.read(syncProvider.notifier).syncNow(); // send my scans first
      final (detail, history) = await (
        api.project(_prefs, widget.projectId),
        api.history(_prefs, widget.projectId, mine: _mine, limit: _limit),
      ).wait;
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _scans = history.scans;
        _total = history.total;
        _error = null;
      });
    } catch (e) {
      final err = e is ParallelWaitError ? e.errors.$1 ?? e.errors.$2 : e;
      if (mounted) setState(() => _error = err is SyncHttpException ? '$err' : 'Can’t reach the server');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    HapticFeedback.selectionClick();
    showHud(context, icon: CupertinoIcons.doc_on_clipboard, message: 'Code Copied');
  }

  void _openList(ComponentList list) {
    ref.read(listsProvider.notifier).select(list.id);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _addList() async {
    final candidates = [
      for (final l in ref.read(listsProvider).lists)
        if (!l.isShared && ref.read(listRepositoryProvider(l.id)).count > 0) l,
    ];
    if (candidates.isEmpty) {
      _alert(context, 'No Lists to Add', 'Import an Excel file first. Lists already in a project aren’t shown.');
      return;
    }
    final picked = await showCupertinoModalPopup<ComponentList>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: const Text('Add a List to This Project'),
        message: const Text('Every device in the project gets a copy.'),
        actions: [
          for (final l in candidates)
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet, l), child: Text(l.name)),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
      ),
    );
    if (picked == null) return;
    await ref.read(syncProvider.notifier).shareList(picked.id, widget.projectId);
    if (!mounted) return;
    showHud(context, icon: CupertinoIcons.cloud_upload, message: 'List Added');
    await _load();
  }

  Future<void> _leave(ProjectInfo p) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text('Leave “${p.name}”?'),
        content: const Text(
          'This device stops syncing the project. Its lists stay here as lists on this device; you can join '
          'again with the code.',
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(projectsProvider.notifier).leave(p.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _alert(context, 'Can’t Leave', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cached = ref.watch(projectsProvider.notifier).byId(widget.projectId);
    ref.watch(projectsProvider);
    final project = _detail?.project ?? cached;
    final lists = ref.watch(listsProvider).lists.where((l) => l.projectId == widget.projectId).toList();
    final pending = ref.watch(syncProvider).pending;
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final blue = context.resolve(CupertinoColors.systemBlue);
    final red = context.resolve(CupertinoColors.systemRed);
    final remote = {for (final r in _detail?.lists ?? const <RemoteList>[]) r.id: r};

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(project?.name ?? 'Project'),
        trailing: _loading
            ? const CupertinoActivityIndicator()
            : CupertinoButton(padding: EdgeInsets.zero, onPressed: _load, child: const Icon(CupertinoIcons.refresh)),
      ),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            CupertinoSliverRefreshControl(onRefresh: _load),
            SliverList.list(
              children: [
                if (_error != null)
                  Section(
                    children: [
                      CupertinoListTile(
                        leading: const IconTile(
                          icon: CupertinoIcons.wifi_exclamationmark,
                          color: CupertinoColors.systemOrange,
                        ),
                        title: Text(_error!, style: TextStyle(color: red)),
                      ),
                    ],
                  ),
                if (project != null)
                  Section(
                    header: 'Code',
                    footer: widget.justCreated
                        ? 'Project created. Enter this code on other phones and computers to add them.'
                        : 'Enter this code on another phone or computer to add it to the project.',
                    children: [
                      CupertinoListTile(
                        leading: const IconTile(icon: CupertinoIcons.number, color: CupertinoColors.systemPurple),
                        title: Text(
                          project.code,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 2),
                        ),
                        trailing: Icon(CupertinoIcons.doc_on_doc, color: blue),
                        onTap: () => _copyCode(project.code),
                      ),
                    ],
                  ),
                if (_detail != null)
                  Section(
                    header: 'Devices',
                    children: [
                      for (final m in _detail!.members)
                        CupertinoListTile(
                          leading: IconTile(
                            icon: CupertinoIcons.device_phone_portrait,
                            color: m.id == _prefs.deviceId ? CupertinoColors.systemGreen : CupertinoColors.systemGrey,
                          ),
                          title: Text(m.id == _prefs.deviceId ? '${m.name} (This Device)' : m.name),
                          additionalInfo: Text('${m.scans} ${m.scans == 1 ? 'scan' : 'scans'}'),
                        ),
                    ],
                  ),
                Section(
                  header: 'Lists',
                  footer: 'Changes to these lists reach every device in the project.',
                  children: [
                    for (final l in lists)
                      CupertinoListTile(
                        leading: const IconTile(icon: CupertinoIcons.list_bullet, color: CupertinoColors.systemBlue),
                        title: Text(l.name),
                        subtitle: Text(
                          [
                            '${ref.watch(listRepositoryProvider(l.id)).count} rows',
                            if (remote[l.remoteId] case final r?) '${r.scans} ${r.scans == 1 ? 'scan' : 'scans'}',
                          ].join(' · '),
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => _openList(l),
                      ),
                    for (final r in remote.values)
                      if (!lists.any((l) => l.remoteId == r.id))
                        CupertinoListTile(
                          leading: const IconTile(
                            icon: CupertinoIcons.cloud_download,
                            color: CupertinoColors.systemGrey,
                          ),
                          title: Text(r.name),
                          additionalInfo: const Text('Downloading…'),
                        ),
                    CupertinoListTile(
                      leading: const IconTile(icon: CupertinoIcons.add, color: CupertinoColors.systemGreen),
                      title: Text('Add a List from This Device…', style: TextStyle(color: blue)),
                      onTap: _addList,
                    ),
                  ],
                ),
                Section(
                  header: 'Last Scans',
                  footer: pending > 0
                      ? '$pending ${pending == 1 ? 'item' : 'items'} on this device waiting to be sent.'
                      : null,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: CupertinoSlidingSegmentedControl<bool>(
                        groupValue: _mine,
                        onValueChanged: (v) {
                          setState(() {
                            _mine = v!;
                            _limit = _page;
                          });
                          _load();
                        },
                        children: const {
                          false: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('All Devices')),
                          true: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('This Device')),
                        },
                      ),
                    ),
                    if (_scans.isEmpty)
                      CupertinoListTile(
                        title: Text(_loading ? 'Loading…' : 'No scans yet', style: TextStyle(color: secondary)),
                      ),
                    for (final s in _scans) _ScanTile(scan: s, mine: s.deviceId == _prefs.deviceId),
                    if (_total > _scans.length)
                      CupertinoListTile(
                        title: Text('Show More (${_total - _scans.length})', style: TextStyle(color: blue)),
                        onTap: () {
                          setState(() => _limit += _page);
                          _load();
                        },
                      ),
                  ],
                ),
                if (project != null)
                  Section(
                    children: [
                      CupertinoListTile(
                        leading: const IconTile(icon: CupertinoIcons.escape, color: CupertinoColors.systemRed),
                        title: Text('Leave Project', style: TextStyle(color: red)),
                        onTap: () => _leave(project),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.scan, required this.mine});

  final ScanRecord scan;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final details = [
      scan.listName,
      mine ? 'This device' : scan.deviceName,
      if (scan.quantity > 0) 'Qty ${scan.quantity}',
      if (scan.supplierPart case final sp? when sp.isNotEmpty) sp,
    ].where((s) => s.isNotEmpty).join(' · ');
    return CupertinoListTile(
      leading: Icon(
        scan.found ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.xmark_circle_fill,
        color: context.resolve(scan.found ? CupertinoColors.systemGreen : CupertinoColors.systemRed),
      ),
      title: Text(scan.mpn),
      subtitle: Text(scan.found ? details : 'Not in list · $details'),
      additionalInfo: Text(timeAgo(scan.scannedAt)),
    );
  }
}

/// "Just now", "5 min ago", "3 h ago", "Yesterday 14:05", or a date.
String timeAgo(DateTime t, {DateTime? now}) {
  now ??= DateTime.now();
  final d = now.difference(t);
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(t.hour)}:${two(t.minute)}';
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  final today = DateTime(now.year, now.month, now.day);
  if (!t.isBefore(today)) return '${d.inHours} h ago';
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'Yesterday $clock';
  return '${t.year}-${two(t.month)}-${two(t.day)} $clock';
}

void _alert(BuildContext context, String title, String message) {
  showCupertinoDialog<void>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
      ],
    ),
  );
}
