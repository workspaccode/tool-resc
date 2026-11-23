import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import 'cloud/cloud_link.dart';
import 'modbus_models.dart';
import 'presets.dart';
import 'protocol/modbus_codec.dart';
import 'protocol/value_format.dart';
import 'transport/modbus_transport.dart';
import 'transport/rtu_transport.dart';
import 'transport/serial_link.dart';
import 'transport/tcp_transport.dart';

/// Everything the Modbus screens show.
class ModbusState {
  const ModbusState({
    required this.config,
    required this.cloud,
    this.polls = const [],
    this.link = LinkState.disconnected,
    this.linkLabel = '',
    this.polling = false,
    this.stats = const ModbusStats(),
    this.cloudState = CloudState.off,
    this.cloudSent = 0,
    this.trendKey,
    this.trend = const [],
    this.customPresets = const [],
  });

  final ModbusConfig config;
  final CloudConfig cloud;
  final List<PollState> polls;
  final LinkState link;
  final String linkLabel;
  final bool polling;
  final ModbusStats stats;
  final CloudState cloudState;
  final int cloudSent;

  /// The register the chart follows: (poll id, index).
  final (int, int)? trendKey;
  final List<double> trend;
  final List<RegisterPreset> customPresets;

  bool get connected => link == LinkState.connected;

  List<RegisterPreset> get presets => [...builtInPresets, ...customPresets];

  ModbusState copyWith({
    ModbusConfig? config,
    CloudConfig? cloud,
    List<PollState>? polls,
    LinkState? link,
    String? linkLabel,
    bool? polling,
    ModbusStats? stats,
    CloudState? cloudState,
    int? cloudSent,
    (int, int)? trendKey,
    bool clearTrend = false,
    List<double>? trend,
    List<RegisterPreset>? customPresets,
  }) => ModbusState(
    config: config ?? this.config,
    cloud: cloud ?? this.cloud,
    polls: polls ?? this.polls,
    link: link ?? this.link,
    linkLabel: linkLabel ?? this.linkLabel,
    polling: polling ?? this.polling,
    stats: stats ?? this.stats,
    cloudState: cloudState ?? this.cloudState,
    cloudSent: cloudSent ?? this.cloudSent,
    trendKey: clearTrend ? null : (trendKey ?? this.trendKey),
    trend: trend ?? this.trend,
    customPresets: customPresets ?? this.customPresets,
  );
}

/// Makes the transport for a config; replaced in tests.
final modbusTransportFactoryProvider = Provider<ModbusTransport Function(ModbusConfig)>(
  (ref) =>
      (c) => switch (c.kind) {
        TransportKind.tcp => TcpTransport(host: c.host.trim(), port: c.port),
        TransportKind.rtu => RtuTransport(SerialLink.create(c.serialPort, c.serial)),
      },
);

/// The traffic and event log (last 500 lines).
class ModbusLog extends Notifier<List<LogEntry>> {
  static const max = 500;

  @override
  List<LogEntry> build() => const [];

  void add(LogKind kind, String text) {
    final next = [...state, LogEntry(DateTime.now(), kind, text)];
    state = next.length > max ? next.sublist(next.length - max) : next;
  }

  void clear() => state = const [];
}

final modbusLogProvider = NotifierProvider<ModbusLog, List<LogEntry>>(ModbusLog.new);

/// Modbus Poll: connects over TCP or serial RTU, polls the defined
/// registers on their own intervals, writes, and — with Cloud Share on —
/// uploads every reading to the cloud backend live.
class ModbusController extends Notifier<ModbusState> {
  static const _configKey = 'modbusConfig';
  static const _pollsKey = 'modbusPolls';
  static const _cloudKey = 'modbusCloud';
  static const _presetsKey = 'modbusPresets';
  static const _trendMax = 300;

  Box<Object> get _box => Hive.box<Object>(Boxes.settings);
  ModbusLog get _log => ref.read(modbusLogProvider.notifier);

  ModbusTransport? _transport;
  final _timers = <int, Timer>{};
  final _busy = <int>{};
  late final CloudLink _cloud;
  Timer? _cloudDebounce;
  int _consecutiveErrors = 0;
  bool _scanCancelled = false;

  @override
  ModbusState build() {
    _cloud = CloudLink(
      onChange: () {
        if (ref.mounted) state = state.copyWith(cloudState: _cloud.state, cloudSent: _cloud.sent);
      },
      onLog: (m, {error = false}) => _info(m, error: error),
    );
    ref.onDispose(() {
      _cloudDebounce?.cancel();
      _stopTimers();
      _transport?.close();
      _cloud.dispose();
    });
    final cloud = CloudConfig.fromMap((_box.get(_cloudKey) as Map?) ?? const {});
    final polls = [
      for (final m in (_box.get(_pollsKey) as List? ?? const []).cast<Map>()) PollState(def: PollDef.fromMap(m)),
    ];
    Future.microtask(() {
      if (ref.mounted) _cloud.configure(state.cloud);
    }); // auto-link if left on
    return ModbusState(
      config: ModbusConfig.fromMap((_box.get(_configKey) as Map?) ?? const {}),
      cloud: cloud,
      polls: polls,
      trendKey: polls.isEmpty ? null : (polls.first.def.id, 0),
      customPresets: [
        for (final m in (_box.get(_presetsKey) as List? ?? const []).cast<Map>()) RegisterPreset.fromMap(m),
      ],
    );
  }

  // --- settings ---

  void updateConfig(ModbusConfig Function(ModbusConfig) change) {
    final next = change(state.config);
    _box.put(_configKey, next.toMap());
    state = state.copyWith(config: next);
  }

  void updateCloud(CloudConfig Function(CloudConfig) change) {
    final next = change(state.cloud);
    final toggled = next.enabled != state.cloud.enabled;
    _box.put(_cloudKey, next.toMap());
    state = state.copyWith(cloud: next);
    // Typing an address shouldn't reconnect on every key.
    _cloudDebounce?.cancel();
    if (toggled) {
      _cloud.configure(next);
    } else {
      _cloudDebounce = Timer(const Duration(milliseconds: 800), () => _cloud.configure(state.cloud));
    }
  }

  // --- connection ---

  Future<void> connect() async {
    if (state.link != LinkState.disconnected) return;
    final config = state.config;
    if (config.kind == TransportKind.rtu && config.serialPort.isEmpty) {
      throw StateError('Choose a serial port first.');
    }
    final transport = ref.read(modbusTransportFactoryProvider)(config)
      ..onFrame = (tx, frame) => _log.add(tx ? LogKind.tx : LogKind.rx, toHex(frame));
    state = state.copyWith(link: LinkState.connecting, linkLabel: transport.label);
    try {
      await transport.open();
    } catch (e) {
      state = state.copyWith(link: LinkState.disconnected);
      _info('Connection failed: $e', error: true);
      rethrow;
    }
    _transport = transport;
    _consecutiveErrors = 0;
    state = state.copyWith(link: LinkState.connected, stats: const ModbusStats());
    _info('Connected — ${transport.label}');
    transport.done.then((_) {
      if (_transport == transport && ref.mounted) _lost('Connection lost (${transport.label}).');
    });
    if (state.polls.isNotEmpty) startPolling();
  }

  Future<void> disconnect() async {
    _stopTimers();
    final t = _transport;
    _transport = null;
    state = state.copyWith(link: LinkState.disconnected, polling: false);
    await t?.close();
    _info('Disconnected.');
  }

  void _lost(String why) {
    _stopTimers();
    _transport = null;
    state = state.copyWith(link: LinkState.disconnected, polling: false);
    _info(why, error: true);
  }

  /// Reads one register (the first poll's, or 4999) to check the device
  /// answers. Returns a message for the user.
  Future<String> testConnection() async {
    final first = state.polls.firstOrNull?.def;
    final fc = first?.func ?? Fc.readHoldingRegisters;
    final address = first?.address ?? 4999;
    final unit = state.config.unitId;
    try {
      final pdu = await _request(unit, ModbusPdu.read(fc, _wire(address), 1));
      final v = ModbusPdu.readValues(pdu, fc, 1).first;
      return 'Unit $unit answered. Address $address = $v (${hex16(v)}).';
    } on ModbusException catch (e) {
      return 'Unit $unit answered with $e — the link works; check the address.';
    }
  }

  // --- polls ---

  int _nextId() {
    final seq = (_box.get('modbusPollSeq') as int? ?? 0) + 1;
    _box.put('modbusPollSeq', seq);
    return seq;
  }

  PollDef newPoll() => PollDef(id: 0, name: 'Poll ${state.polls.length + 1}', address: 0, quantity: 10);

  void savePoll(PollDef def) {
    final isNew = def.id == 0;
    final saved = isNew ? PollDef.fromMap({...def.toMap(), 'id': _nextId()}) : def;
    final polls = [
      for (final p in state.polls)
        if (p.def.id == saved.id)
          PollState(
            def: saved,
            values: p.def.quantity == saved.quantity && p.def.func == saved.func ? p.values : const [],
          )
        else
          p,
      if (isNew) PollState(def: saved),
    ];
    _setPolls(polls);
    if (state.trendKey == null) state = state.copyWith(trendKey: (saved.id, 0), trend: const []);
    if (state.polling) _schedule(saved);
  }

  void removePoll(int id) {
    _timers.remove(id)?.cancel();
    _setPolls([
      for (final p in state.polls)
        if (p.def.id != id) p,
    ]);
    if (state.trendKey?.$1 == id) {
      final first = state.polls.firstOrNull;
      state = state.copyWith(
        trendKey: first == null ? null : (first.def.id, 0),
        clearTrend: first == null,
        trend: const [],
      );
    }
  }

  void addPreset(RegisterPreset p) =>
      savePoll(PollDef(id: 0, name: p.name, func: p.func, address: p.address, quantity: p.count));

  void _setPolls(List<PollState> polls) {
    _box.put(_pollsKey, [for (final p in polls) p.def.toMap()]);
    state = state.copyWith(polls: polls);
  }

  void startPolling() {
    if (!state.connected) return;
    for (final p in state.polls) {
      _schedule(p.def);
    }
    state = state.copyWith(polling: true);
  }

  void stopPolling() {
    _stopTimers();
    state = state.copyWith(polling: false);
  }

  void _schedule(PollDef def) {
    _timers.remove(def.id)?.cancel();
    unawaited(_runPoll(def.id));
    _timers[def.id] = Timer.periodic(
      Duration(milliseconds: def.intervalMs.clamp(50, 3600000)),
      (_) => _runPoll(def.id),
    );
  }

  void _stopTimers() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  /// Reads one poll now. Skipped while its previous read is still waiting.
  Future<void> _runPoll(int id) async {
    final def = state.polls.where((p) => p.def.id == id).firstOrNull?.def;
    if (def == null || !state.connected || !_busy.add(id)) return;
    try {
      final unit = state.config.unitId;
      final pdu = await _request(unit, ModbusPdu.read(def.func, _wire(def.address), def.quantity));
      final values = ModbusPdu.readValues(pdu, def.func, def.quantity);
      _consecutiveErrors = 0;
      _applyValues(id, values);
      _cloud.push(pollId: id, name: def.name, func: def.func, addr: def.address, values: values, unitId: unit);
    } on ModbusException catch (e) {
      _consecutiveErrors = 0; // the device answered
      _setError(id, '$e');
      _info('Poll “${def.name}”: $e', error: true);
    } catch (e) {
      // A silent or garbled device isn't a dead port: only count failures of
      // the link itself, so a wrong unit ID or baud rate never drops the
      // connection.
      if (_isLinkFailure(e)) _consecutiveErrors++;
      _setError(id, '$e');
      _info('Poll “${def.name}”: $e', error: true);
    } finally {
      _busy.remove(id);
    }
  }

  void _applyValues(int id, List<int> values) {
    if (!ref.mounted) return;
    final now = DateTime.now();
    final polls = [
      for (final p in state.polls)
        if (p.def.id == id)
          p.copyWith(
            values: values,
            clearError: true,
            lastAt: now,
            reads: p.reads + 1,
            changed: {
              for (var i = 0; i < values.length; i++)
                if (i >= p.values.length || p.values[i] != values[i]) i,
            },
          )
        else
          p,
    ];
    var trend = state.trend;
    if (state.trendKey case (final pid, final index) when pid == id && index < values.length) {
      final v = _trendValue(values, index, state.config.format);
      trend = [...trend, v];
      if (trend.length > _trendMax) trend = trend.sublist(trend.length - _trendMax);
    }
    state = state.copyWith(polls: polls, trend: trend);
  }

  /// The charted number: 32-bit formats as shown, others as signed 16-bit.
  double _trendValue(List<int> values, int index, ValueFormat format) {
    final shown = format.registers == 2 ? formatValue(values, index, format) : null;
    final v = values[index] & 0xFFFF;
    return double.tryParse(shown ?? '') ??
        (format == ValueFormat.unsigned ? v : (v > 0x7FFF ? v - 0x10000 : v)).toDouble();
  }

  void _setError(int id, String error) {
    if (!ref.mounted) return;
    state = state.copyWith(polls: [for (final p in state.polls) p.def.id == id ? p.copyWith(error: error) : p]);
  }

  void selectTrend(int pollId, int index) {
    if (state.trendKey == (pollId, index)) return;
    state = state.copyWith(trendKey: (pollId, index), trend: const []);
  }

  // --- writing ---

  /// FC 05/06/15/16. Values: numbers (decimal or 0x hex); coils use 0/1.
  Future<void> write(int fc, int address, List<int> values) async {
    final a = _wire(address);
    final pdu = switch (fc) {
      Fc.writeSingleCoil => ModbusPdu.writeSingleCoil(a, values.first != 0),
      Fc.writeSingleRegister => ModbusPdu.writeSingleRegister(a, values.first),
      Fc.writeMultipleCoils => ModbusPdu.writeMultipleCoils(a, [for (final v in values) v != 0]),
      Fc.writeMultipleRegisters => ModbusPdu.writeMultipleRegisters(a, values),
      _ => throw ArgumentError('Function $fc can’t write'),
    };
    final resp = await _request(state.config.unitId, pdu);
    ModbusPdu.checkException(resp);
    _info('Write OK (FC${fc.toString().padLeft(2, '0')} @ $address: ${values.join(', ')})');
  }

  /// Sends any PDU and returns the response PDU (exceptions included).
  Future<Uint8List> sendRaw(int fc, Uint8List data) => _request(state.config.unitId, Uint8List.fromList([fc, ...data]));

  // --- scanner ---

  /// Asks every unit id in [from]..[to] for one register (or FC 17).
  Stream<({int unit, String result, bool found})> scan({
    required int from,
    required int to,
    required int fc,
    required int address,
  }) async* {
    _scanCancelled = false;
    final pdu = fc == Fc.reportServerId
        ? Uint8List.fromList([Fc.reportServerId])
        : ModbusPdu.read(fc, _wire(address), 1);
    for (var unit = from; unit <= to && !_scanCancelled; unit++) {
      try {
        final resp = await _request(unit, pdu);
        yield (unit: unit, result: 'Found · ${toHex(resp)}', found: true);
      } on ModbusTimeout {
        yield (unit: unit, result: 'Timeout', found: false);
      } catch (e) {
        yield (unit: unit, result: '$e', found: false);
      }
      if (!state.connected) break;
    }
  }

  void cancelScan() => _scanCancelled = true;

  // --- presets & export ---

  int importPresets(String text) {
    final added = parseRegisterJson(text);
    final all = [...state.customPresets, ...added];
    _box.put(_presetsKey, [for (final p in all) p.toMap()]);
    state = state.copyWith(customPresets: all);
    return added.length;
  }

  void clearCustomPresets() {
    _box.delete(_presetsKey);
    state = state.copyWith(customPresets: const []);
  }

  /// The table as CSV: poll, address, value (in the current format), hex.
  String exportCsv() {
    final f = state.config.format;
    final b = StringBuffer('Poll,Function,Address,Value,Hex,Time\n');
    for (final p in state.polls) {
      final step = p.def.isBits ? 1 : f.registers;
      for (var i = 0; i < p.values.length; i += step) {
        final name = p.def.name.replaceAll('"', '""');
        b.writeln(
          '"$name",${p.def.func},${p.def.address + i},${formatValue(p.values, i, f, bits: p.def.isBits)},'
          '${p.def.isBits ? p.values[i] : hex16(p.values[i])},${p.lastAt?.toIso8601String() ?? ''}',
        );
      }
    }
    return b.toString();
  }

  // --- helpers ---

  int _wire(int address) {
    final a = address + state.config.addressOffset;
    if (a < 0 || a > 0xFFFF) throw ArgumentError('Address $a (with offset) is out of range 0–65535');
    return a;
  }

  Future<Uint8List> _request(int unit, Uint8List pdu) async {
    final t = _transport;
    if (t == null || !state.connected) throw StateError('Not connected');
    final start = DateTime.now();
    final s = state.stats;
    try {
      final resp = await t.request(unit, pdu, timeout: state.config.timeout);
      if (ref.mounted) {
        state = state.copyWith(
          stats: ModbusStats(
            requests: s.requests + 1,
            errors: s.errors,
            lastMs: DateTime.now().difference(start).inMilliseconds,
          ),
        );
      }
      return resp;
    } catch (_) {
      if (ref.mounted) {
        final s2 = state.stats;
        state = state.copyWith(
          stats: ModbusStats(requests: s2.requests + 1, errors: s2.errors + 1, lastMs: s2.lastMs),
        );
        // A serial port that keeps failing is probably gone.
        if (_consecutiveErrors >= 10 && state.config.kind == TransportKind.rtu) {
          _lost('Too many errors in a row — serial link lost. Reconnect.');
        }
      }
      rethrow;
    }
  }

  static bool _isLinkFailure(Object e) => e is! ModbusTimeout && e is! FormatException && e is! ArgumentError;

  void _info(String text, {bool error = false}) {
    if (ref.mounted) _log.add(error ? LogKind.error : LogKind.info, text);
  }
}

final modbusProvider = NotifierProvider<ModbusController, ModbusState>(ModbusController.new);
