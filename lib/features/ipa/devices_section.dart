import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../widgets/clickable_tile.dart';
import '../../widgets/section.dart';
import 'ios_devices.dart';
import 'ipa_builder.dart';

sealed class _Status {
  const _Status();
}

class _Installing extends _Status {
  const _Installing();
}

class _Installed extends _Status {
  const _Installed();
}

class _Failed extends _Status {
  const _Failed(this.error);
  final IpaException error;
}

/// Connected iPhones, iPads and simulators: pick some and install [app].
class DevicesSection extends StatefulWidget {
  const DevicesSection({super.key, required this.app, this.service, this.onBusy});

  final AppBundleInfo app;

  /// Injected in tests.
  final IosDeviceService? service;

  /// Told while installing, so the rest of the screen can wait.
  final ValueChanged<bool>? onBusy;

  @override
  State<DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<DevicesSection> {
  late final IosDeviceService _service = widget.service ?? IosDeviceService();
  List<IosDevice> _devices = const [];
  final _selected = <String>{};
  final _status = <String, _Status>{};
  bool _searching = false;
  bool _installing = false;
  IpaException? _error;

  /// Xcode installs many simulators; they stay folded unless the app is a
  /// simulator build (or the user opens them).
  bool? _showSimulatorsChoice;
  bool get _showSimulators => _showSimulatorsChoice ?? widget.app.isSimulatorBuild;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void didUpdateWidget(DevicesSection old) {
    super.didUpdateWidget(old);
    if (old.app.appPath != widget.app.appPath) {
      // A different build: earlier results no longer apply.
      setState(() {
        _status.clear();
        _selected.removeWhere((id) => !_canInstall(id));
      });
    }
  }

  bool _canInstall(String id) => switch (_devices.where((d) => d.id == id).firstOrNull) {
    final d? => d.blockReason(widget.app) == null,
    null => false,
  };

  Future<void> _discover() async {
    setState(() => _searching = true);
    try {
      final devices = await _service.discover();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
        _selected.removeWhere((id) => !_canInstall(id));
        // One compatible device: select it so Install is one tap away.
        final usable = devices.where((d) => d.blockReason(widget.app) == null && !d.isSimulator).toList();
        if (_selected.isEmpty && usable.length == 1) _selected.add(usable.single.id);
      });
    } on IpaException catch (e) {
      if (mounted) setState(() => _error = e);
    } catch (e) {
      if (mounted) setState(() => _error = IpaException('Can’t Find Devices', '$e'));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _install() async {
    final targets = _devices.where((d) => _selected.contains(d.id)).toList();
    if (targets.isEmpty) return;
    setState(() {
      _installing = true;
      for (final d in targets) {
        _status.remove(d.id);
      }
    });
    widget.onBusy?.call(true);
    var failed = 0;
    for (final d in targets) {
      if (!mounted) return;
      setState(() => _status[d.id] = const _Installing());
      try {
        await _service.install(d, widget.app);
        if (mounted) setState(() => _status[d.id] = const _Installed());
      } on IpaException catch (e) {
        failed++;
        if (mounted) setState(() => _status[d.id] = _Failed(e));
      } catch (e) {
        failed++;
        if (mounted) setState(() => _status[d.id] = _Failed(IpaException('Install Failed', '$e')));
      }
    }
    widget.onBusy?.call(false);
    if (!mounted) return;
    setState(() => _installing = false);
    if (failed == 0) {
      HapticFeedback.mediumImpact();
    } else if (targets.length == 1) {
      _showError((_status[targets.single.id]! as _Failed).error);
    }
  }

  void _showError(IpaException e) {
    showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(e.title),
        content: Text(e.message),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
        ],
      ),
    );
  }

  void _toggle(IosDevice d) {
    final status = _status[d.id];
    if (status is _Failed && !_installing) return _showError(status.error);
    if (_installing || d.blockReason(widget.app) != null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _status.remove(d.id); // Back to the checkmark after “Installed”.
      _selected.contains(d.id) ? _selected.remove(d.id) : _selected.add(d.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = _selected.length;
    return Column(
      children: [
        Section(
          header: 'Install on Device',
          footer: _footer(),
          children: [
            ClickableTile(
              leading: _searching
                  ? const CupertinoActivityIndicator()
                  : const Icon(CupertinoIcons.arrow_clockwise, size: 22),
              title: Text(_searching ? 'Searching…' : 'Search for Devices'),
              onTap: _searching || _installing ? null : _discover,
            ),
            if (_error != null)
              CupertinoListTile(
                leading: Icon(
                  CupertinoIcons.exclamationmark_triangle_fill,
                  color: context.resolve(CupertinoColors.systemOrange),
                  size: 22,
                ),
                title: Text(_error!.title),
                subtitle: Text(_error!.message, maxLines: 4),
              ),
            for (final d in _devices)
              if (!d.isSimulator) _deviceRow(d),
            if (_devices.any((d) => d.isSimulator)) _simulatorsRow(),
            if (_showSimulators)
              for (final d in _devices)
                if (d.isSimulator) _deviceRow(d),
          ],
        ),
        if (_devices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: count == 0 || _installing ? null : _install,
                child: _installing
                    ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                    : Text(count <= 1 ? 'Install' : 'Install on $count Devices'),
              ),
            ),
          ),
      ],
    );
  }

  String? _footer() {
    if (_error != null) return null;
    if (_searching) return null;
    final app = widget.app;
    if (app.isSimulatorBuild) {
      return _devices.any((d) => d.isSimulator)
          ? 'Simulator builds install on simulators. The simulator starts if it isn’t running.'
          : 'No simulators found. Add one in Xcode › Window › Devices and Simulators.';
    }
    if (!_devices.any((d) => !d.isSimulator)) {
      return 'No iPhone or iPad found. Connect one with a cable, unlock it and tap Trust, then search again.';
    }
    if (!app.signed) {
      return 'Devices only install signed apps. Build without --no-codesign, or with --simulator to try it in a simulator.';
    }
    return 'Devices need Developer Mode on and a provisioning profile that includes them.';
  }

  Widget _simulatorsRow() {
    final sims = _devices.where((d) => d.isSimulator);
    final picked = sims.where((d) => _selected.contains(d.id)).length;
    return ClickableTile(
      leading: Icon(
        _showSimulators ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
        size: 18,
        color: context.resolve(CupertinoColors.secondaryLabel),
      ),
      title: const Text('Simulators'),
      additionalInfo: Text(picked > 0 ? '$picked of ${sims.length} selected' : '${sims.length}'),
      onTap: () => setState(() => _showSimulatorsChoice = !_showSimulators),
    );
  }

  Widget _deviceRow(IosDevice d) {
    final blocked = d.blockReason(widget.app);
    final status = _status[d.id];
    final selected = _selected.contains(d.id);
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    final disabled = context.resolve(CupertinoColors.tertiaryLabel);

    final (String subtitle, Color subtitleColor) = switch (status) {
      _Installing() => ('Installing…', secondary),
      _Installed() => ('Installed', context.resolve(CupertinoColors.systemGreen)),
      _Failed(:final error) => ('${error.title} — tap for details', context.resolve(CupertinoColors.systemRed)),
      null when blocked != null => (blocked, disabled),
      null => (d.detail, secondary),
    };

    final icon = d.isSimulator
        ? CupertinoIcons.device_laptop
        : d.isIpad
        ? CupertinoIcons.device_phone_landscape
        : CupertinoIcons.device_phone_portrait;

    return ClickableTile(
      leading: Icon(icon, size: 24, color: blocked == null ? context.resolve(CupertinoColors.systemBlue) : disabled),
      title: Text(d.name, style: TextStyle(color: blocked == null ? null : disabled)),
      subtitle: Text(subtitle, style: AppText.footnote.copyWith(color: subtitleColor)),
      additionalInfo: blocked == null || status != null ? null : Text(d.detail, style: TextStyle(color: disabled)),
      trailing: SizedBox(
        width: 24,
        child: switch (status) {
          _Installing() => const CupertinoActivityIndicator(),
          _Installed() => Icon(
            CupertinoIcons.checkmark_circle_fill,
            color: context.resolve(CupertinoColors.systemGreen),
          ),
          _Failed() => Icon(CupertinoIcons.xmark_circle_fill, color: context.resolve(CupertinoColors.systemRed)),
          null when blocked != null => null,
          null => Icon(
            selected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
            color: context.resolve(selected ? CupertinoColors.systemBlue : CupertinoColors.systemGrey3),
          ),
        },
      ),
      onTap: blocked == null || status is _Failed ? () => _toggle(d) : null,
    );
  }
}
