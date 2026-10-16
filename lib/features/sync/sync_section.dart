import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../widgets/hud.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/prompt.dart';
import '../../widgets/section.dart';
import 'sync_controller.dart';
import 'sync_prefs.dart';

/// Settings › Server Sync: optional; sends lists and scans to a ToolsResc
/// server, where scans are counted by part, list and device.
class SyncSection extends ConsumerStatefulWidget {
  const SyncSection({super.key});

  @override
  ConsumerState<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends ConsumerState<SyncSection> {
  bool _busy = false;

  SyncPrefsNotifier get _prefs => ref.read(syncPrefsProvider.notifier);
  SyncController get _sync => ref.read(syncProvider.notifier);

  Future<String?> _askServer() => showTextPrompt(
    context,
    title: 'Server Address',
    message: 'The address of your ToolsResc server, e.g. 192.168.1.20:8080',
    initialValue: ref.read(syncPrefsProvider).serverUrl,
    confirmLabel: 'Save',
  );

  Future<void> _toggle(bool on) async {
    HapticFeedback.selectionClick();
    if (!on) {
      _prefs.update((p) => p.copyWith(enabled: false));
      return;
    }
    var server = ref.read(syncPrefsProvider).serverUrl;
    if (server.isEmpty) {
      server = await _askServer() ?? '';
      if (server.isEmpty || !mounted) return;
    }
    _prefs.update((p) => p.copyWith(enabled: true, serverUrl: server));
    // The server needs the lists to check and count scans against them.
    await _run(() async {
      final n = await _sync.uploadAllLists();
      return n == 0 ? 'Sync On' : 'Sending $n ${n == 1 ? 'list' : 'lists'}';
    });
  }

  Future<void> _editServer() async {
    final server = await _askServer();
    if (server != null) _prefs.update((p) => p.copyWith(serverUrl: server));
  }

  Future<void> _editApiKey() async {
    final key = await showTextPrompt(
      context,
      title: 'API Key',
      message: 'The key set on the server (TOOLSRESC_API_KEY). Enter - for none.',
      initialValue: ref.read(syncPrefsProvider).apiKey,
      confirmLabel: 'Save',
    );
    if (key != null) _prefs.update((p) => p.copyWith(apiKey: key == '-' ? '' : key));
  }

  Future<void> _editDeviceName() async {
    final name = await showTextPrompt(
      context,
      title: 'Device Name',
      message: 'Shown on the server next to this device’s scans.',
      initialValue: ref.read(syncPrefsProvider).deviceName,
      confirmLabel: 'Save',
    );
    if (name != null) _prefs.update((p) => p.copyWith(deviceName: name));
  }

  Future<void> _testConnection() => _run(() async {
    await _sync.testConnection();
    await _sync.flush();
    return 'Connected';
  });

  Future<void> _uploadLists() => _run(() async {
    final n = await _sync.uploadAllLists();
    return n == 0 ? 'No Lists to Send' : 'Sending $n ${n == 1 ? 'list' : 'lists'}';
  });

  /// Runs an action with a spinner, then shows its message or the error.
  Future<void> _run(Future<String> Function() action) async {
    setState(() => _busy = true);
    try {
      final message = await action();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showHud(context, icon: CupertinoIcons.checkmark_circle, message: message);
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.vibrate();
      showHud(context, icon: CupertinoIcons.exclamationmark_circle, message: 'Can’t Connect');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusText(SyncStatus s) {
    if (s.syncing) return 'Sending ${s.pending}…';
    if (s.pending > 0) return '${s.pending} waiting';
    return s.lastSyncedAt == null ? 'Nothing to send' : 'Up to date';
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(syncPrefsProvider);
    final status = ref.watch(syncProvider);
    final blue = context.resolve(CupertinoColors.systemBlue);
    final red = context.resolve(CupertinoColors.systemRed);

    return Section(
      header: 'Server Sync',
      footer: prefs.enabled
          ? 'Imported lists and every scan are sent to your server, where scans are counted by part, list '
                'and device. Offline, they wait on this device and are sent when the server can be reached.'
          : 'Optional. Turn on to send lists and scans to your ToolsResc server and count scans by part, '
                'list and device. When off, nothing leaves this device.',
      children: [
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.cloud_upload_fill, color: CupertinoColors.systemTeal),
          title: const Text('Sync to Server'),
          trailing: CupertinoSwitch(value: prefs.enabled, onChanged: _busy ? null : _toggle),
          onTap: _busy ? null : () => _toggle(!prefs.enabled),
        ),
        if (prefs.enabled) ...[
          CupertinoListTile(
            leading: const IconTile(icon: CupertinoIcons.globe, color: CupertinoColors.systemBlue),
            title: const Text('Server'),
            additionalInfo: Text(prefs.serverLabel.isEmpty ? 'Not Set' : prefs.serverLabel),
            trailing: const CupertinoListTileChevron(),
            onTap: _editServer,
          ),
          CupertinoListTile(
            leading: const IconTile(icon: CupertinoIcons.lock_fill, color: CupertinoColors.systemGrey),
            title: const Text('API Key'),
            additionalInfo: Text(prefs.apiKey.isEmpty ? 'None' : 'Set'),
            trailing: const CupertinoListTileChevron(),
            onTap: _editApiKey,
          ),
          CupertinoListTile(
            leading: const IconTile(icon: CupertinoIcons.device_phone_portrait, color: CupertinoColors.systemIndigo),
            title: const Text('Device Name'),
            additionalInfo: Text(prefs.deviceName),
            trailing: const CupertinoListTileChevron(),
            onTap: _editDeviceName,
          ),
          CupertinoListTile(
            leading: IconTile(
              icon: status.lastError == null
                  ? CupertinoIcons.checkmark_seal_fill
                  : CupertinoIcons.exclamationmark_triangle_fill,
              color: status.lastError == null ? CupertinoColors.systemGreen : CupertinoColors.systemOrange,
            ),
            title: const Text('Status'),
            subtitle: status.lastError == null ? null : Text(status.lastError!, style: TextStyle(color: red)),
            additionalInfo: Text(_statusText(status)),
            trailing: status.syncing || _busy ? const CupertinoActivityIndicator() : null,
          ),
          CupertinoListTile(
            leading: const IconTile(icon: CupertinoIcons.arrow_2_circlepath, color: CupertinoColors.systemBlue),
            title: Text('Test Connection & Sync Now', style: TextStyle(color: blue)),
            onTap: _busy ? null : _testConnection,
          ),
          CupertinoListTile(
            leading: const IconTile(icon: CupertinoIcons.tray_arrow_up_fill, color: CupertinoColors.systemBlue),
            title: Text('Send All Lists Again', style: TextStyle(color: blue)),
            onTap: _busy ? null : _uploadLists,
          ),
        ],
      ],
    );
  }
}
