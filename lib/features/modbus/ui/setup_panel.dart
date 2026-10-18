import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../widgets/icon_tile.dart';
import '../../../widgets/section.dart';
import '../cloud/cloud_link.dart';
import '../modbus_controller.dart';
import '../modbus_models.dart';
import '../transport/serial_link.dart';
import 'form_rows.dart';
import 'sheets.dart';

const _bauds = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];

/// Connection settings + connect button.
class ConnectionSection extends ConsumerStatefulWidget {
  const ConnectionSection({super.key});

  @override
  ConsumerState<ConnectionSection> createState() => _ConnectionSectionState();
}

class _ConnectionSectionState extends ConsumerState<ConnectionSection> {
  bool _busy = false;

  ModbusController get _modbus => ref.read(modbusProvider.notifier);

  void _set(ModbusConfig Function(ModbusConfig) change) => _modbus.updateConfig(change);

  Future<void> _toggleConnection() async {
    final connected = ref.read(modbusProvider).link != LinkState.disconnected;
    setState(() => _busy = true);
    try {
      if (connected) {
        await _modbus.disconnect();
      } else {
        await _modbus.connect();
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      if (mounted) {
        HapticFeedback.vibrate();
        showAlert(context, 'Can’t Connect', '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      final message = await _modbus.testConnection();
      if (mounted) showAlert(context, 'Connection Test', message);
    } catch (e) {
      if (mounted) {
        showAlert(
          context,
          'Test Failed',
          '$e\n\nOn serial, check the baud rate (try 9600), parity (try Even) and Unit ID.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPort() async {
    try {
      final ports = await SerialLink.listPorts();
      if (!mounted) return;
      if (ports.isEmpty) {
        return showAlert(
          context,
          'No Serial Ports',
          'Connect the RS485/USB adapter and try again. On Android, use a USB-OTG cable.',
        );
      }
      final picked = await pickOption<SerialPortInfo>(
        context,
        title: 'Serial Port',
        options: ports,
        labelOf: (p) => p.label,
      );
      if (picked != null) _set((c) => c.copyWith(serialPort: picked.id));
    } catch (e) {
      if (mounted) showAlert(context, 'Can’t List Ports', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(modbusProvider);
    final c = s.config;
    final locked = s.link != LinkState.disconnected;
    final blue = context.resolve(CupertinoColors.systemBlue);
    final red = context.resolve(CupertinoColors.systemRed);

    return Column(
      children: [
        Section(
          header: 'Connection',
          footer: locked ? 'Disconnect to change the connection.' : null,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSlidingSegmentedControl<TransportKind>(
                groupValue: c.kind,
                onValueChanged: locked ? (_) {} : (k) => _set((c) => c.copyWith(kind: k)),
                children: {
                  TransportKind.tcp: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('Modbus TCP'),
                  ),
                  TransportKind.rtu: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(SerialLink.isSupported ? 'Serial RTU' : 'RTU (n/a)'),
                  ),
                },
              ),
            ),
            if (c.kind == TransportKind.tcp) ...[
              TextRow(
                label: 'IP Address',
                value: c.host,
                enabled: !locked,
                placeholder: '192.168.1.10',
                onChanged: (v) => _set((c) => c.copyWith(host: v.trim())),
              ),
              TextRow(
                label: 'Port',
                value: '${c.port}',
                numeric: true,
                enabled: !locked,
                onChanged: (v) => _set((c) => c.copyWith(port: int.tryParse(v) ?? 502)),
              ),
              TextRow(
                label: 'Timeout (ms)',
                value: '${c.tcpTimeoutMs}',
                numeric: true,
                onChanged: (v) => _set((c) => c.copyWith(tcpTimeoutMs: int.tryParse(v) ?? 3000)),
              ),
            ] else ...[
              CupertinoListTile(
                title: const Text('Port'),
                additionalInfo: Text(c.serialPort.isEmpty ? 'Choose…' : c.serialPort),
                trailing: const CupertinoListTileChevron(),
                onTap: locked || !SerialLink.isSupported ? null : _pickPort,
              ),
              PickerRow<int>(
                label: 'Baud Rate',
                value: c.serial.baudRate,
                options: _bauds,
                labelOf: (b) => '$b',
                enabled: !locked,
                onChanged: (b) => _set((c) => c.copyWith(serial: _serial(c.serial, baudRate: b))),
              ),
              PickerRow<int>(
                label: 'Data Bits',
                value: c.serial.dataBits,
                options: const [7, 8],
                labelOf: (b) => '$b',
                enabled: !locked,
                onChanged: (b) => _set((c) => c.copyWith(serial: _serial(c.serial, dataBits: b))),
              ),
              PickerRow<Parity>(
                label: 'Parity',
                value: c.serial.parity,
                options: Parity.values,
                labelOf: (p) => '${p.name[0].toUpperCase()}${p.name.substring(1)}',
                enabled: !locked,
                onChanged: (p) => _set((c) => c.copyWith(serial: _serial(c.serial, parity: p))),
              ),
              PickerRow<int>(
                label: 'Stop Bits',
                value: c.serial.stopBits,
                options: const [1, 2],
                labelOf: (b) => '$b',
                enabled: !locked,
                onChanged: (b) => _set((c) => c.copyWith(serial: _serial(c.serial, stopBits: b))),
              ),
              TextRow(
                label: 'Timeout (ms)',
                value: '${c.rtuTimeoutMs}',
                numeric: true,
                onChanged: (v) => _set((c) => c.copyWith(rtuTimeoutMs: int.tryParse(v) ?? 1500)),
              ),
            ],
            TextRow(
              label: 'Unit ID',
              value: '${c.unitId}',
              numeric: true,
              onChanged: (v) => _set((c) => c.copyWith(unitId: (int.tryParse(v) ?? 1).clamp(0, 247))),
            ),
            TextRow(
              label: 'Address Offset',
              value: '${c.addressOffset}',
              numeric: true,
              signed: true,
              onChanged: (v) => _set((c) => c.copyWith(addressOffset: int.tryParse(v) ?? 0)),
            ),
          ],
        ),
        Section(
          children: [
            CupertinoListTile(
              leading: IconTile(
                icon: locked ? CupertinoIcons.xmark : CupertinoIcons.link,
                color: locked ? CupertinoColors.systemRed : CupertinoColors.systemGreen,
              ),
              title: Text(switch (s.link) {
                LinkState.connected => 'Disconnect',
                LinkState.connecting => 'Connecting…',
                LinkState.disconnected => 'Connect',
              }, style: TextStyle(color: locked ? red : blue, fontWeight: FontWeight.w600)),
              additionalInfo: s.connected ? Text(s.linkLabel) : null,
              trailing: _busy ? const CupertinoActivityIndicator() : null,
              onTap: _busy || s.link == LinkState.connecting ? null : _toggleConnection,
            ),
            if (s.connected)
              CupertinoListTile(
                leading: const IconTile(icon: CupertinoIcons.checkmark_seal, color: CupertinoColors.systemBlue),
                title: Text('Test Connection', style: TextStyle(color: blue)),
                onTap: _busy ? null : _test,
              ),
          ],
        ),
      ],
    );
  }

  static SerialSettings _serial(SerialSettings s, {int? baudRate, int? dataBits, Parity? parity, int? stopBits}) =>
      SerialSettings(
        baudRate: baudRate ?? s.baudRate,
        dataBits: dataBits ?? s.dataBits,
        parity: parity ?? s.parity,
        stopBits: stopBits ?? s.stopBits,
      );
}

/// The poll definitions, with start/stop.
class PollsSection extends ConsumerWidget {
  const PollsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modbusProvider);
    final modbus = ref.read(modbusProvider.notifier);
    final blue = context.resolve(CupertinoColors.systemBlue);
    final red = context.resolve(CupertinoColors.systemRed);
    final secondary = context.resolve(CupertinoColors.secondaryLabel);

    return Section(
      header: 'Polls',
      footer: s.polls.isEmpty
          ? 'Add a poll: e.g. FC 04, address 5030, quantity 1 reads the inverter’s real-time power. '
                'The Library has ready-made registers.'
          : null,
      children: [
        for (final p in s.polls)
          CupertinoListTile(
            leading: IconTile(
              icon: p.def.isBits ? CupertinoIcons.circle_grid_3x3_fill : CupertinoIcons.number_square_fill,
              color: p.error != null ? CupertinoColors.systemOrange : CupertinoColors.systemIndigo,
            ),
            title: Text(p.def.name),
            subtitle: Text(
              p.error ?? p.def.summary,
              style: TextStyle(color: p.error != null ? red : secondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(32, 32),
              onPressed: () => modbus.removePoll(p.def.id),
              child: Icon(CupertinoIcons.minus_circle_fill, color: red, size: 22),
            ),
            onTap: () => showPollEditor(context, poll: p.def),
          ),
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.add, color: CupertinoColors.systemGreen),
          title: Text('Add Poll…', style: TextStyle(color: blue)),
          onTap: () => showPollEditor(context),
        ),
        if (s.connected && s.polls.isNotEmpty)
          CupertinoListTile(
            leading: IconTile(
              icon: s.polling ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              color: s.polling ? CupertinoColors.systemOrange : CupertinoColors.systemGreen,
            ),
            title: Text(s.polling ? 'Stop Polling' : 'Start Polling', style: TextStyle(color: blue)),
            onTap: s.polling ? modbus.stopPolling : modbus.startPolling,
          ),
      ],
    );
  }
}

/// ☁️ Cloud Share: upload every reading to the cloud backend.
class CloudSection extends ConsumerWidget {
  const CloudSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modbusProvider);
    final cloud = s.cloud;
    final modbus = ref.read(modbusProvider.notifier);
    void set(CloudConfig Function(CloudConfig) change) => modbus.updateCloud(change);

    final (statusText, statusColor) = switch (s.cloudState) {
      CloudState.live => ('● Live · ${s.cloudSent} sent', CupertinoColors.systemGreen),
      CloudState.connecting => ('○ Connecting…', CupertinoColors.systemOrange),
      CloudState.off => ('○ Off', CupertinoColors.secondaryLabel),
    };

    return Section(
      header: 'Cloud Share',
      footer: cloud.enabled
          ? 'Every poll reading is sent live to ${cloud.ingestUri}. Phones, browsers and dashboards get it from '
                '${cloud.feedUri}. If the link drops, the app retries every 5 seconds.'
          : 'Turn on to send every reading to your cloud backend in real time, tagged with the Site and Device ids, '
                'for all devices watching that site.',
      children: [
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.cloud_upload_fill, color: CupertinoColors.systemTeal),
          title: const Text('Upload Live'),
          trailing: CupertinoSwitch(
            value: cloud.enabled,
            onChanged: (v) => set((c) => c.copyWith(enabled: v)),
          ),
        ),
        TextRow(
          label: 'Backend',
          value: cloud.url,
          placeholder: 'ws://host:8790',
          width: 200,
          onChanged: (v) => set((c) => c.copyWith(url: v.trim())),
        ),
        TextRow(
          label: 'Site ID',
          value: cloud.site,
          onChanged: (v) => set((c) => c.copyWith(site: v.trim())),
        ),
        TextRow(
          label: 'Device ID',
          value: cloud.device,
          onChanged: (v) => set((c) => c.copyWith(device: v.trim())),
        ),
        CupertinoListTile(
          title: const Text('Status'),
          additionalInfo: Text(statusText, style: TextStyle(color: context.resolve(statusColor))),
        ),
      ],
    );
  }
}
