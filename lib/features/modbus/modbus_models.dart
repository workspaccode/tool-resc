import 'protocol/modbus_codec.dart';
import 'protocol/value_format.dart';
import 'transport/serial_link.dart';

enum TransportKind { tcp, rtu }

/// Connection and display settings, saved on the device.
class ModbusConfig {
  const ModbusConfig({
    this.kind = TransportKind.tcp,
    this.host = '192.168.1.10',
    this.port = 502,
    this.tcpTimeoutMs = 3000,
    this.serialPort = '',
    this.serial = const SerialSettings(),
    this.rtuTimeoutMs = 1500,
    this.unitId = 1,
    this.addressOffset = 0,
    this.format = ValueFormat.signed,
  });

  factory ModbusConfig.fromMap(Map m) {
    const d = ModbusConfig();
    return ModbusConfig(
      kind: TransportKind.values.asNameMap()[m['kind']] ?? d.kind,
      host: m['host'] as String? ?? d.host,
      port: m['port'] as int? ?? d.port,
      tcpTimeoutMs: m['tcpTimeoutMs'] as int? ?? d.tcpTimeoutMs,
      serialPort: m['serialPort'] as String? ?? d.serialPort,
      serial: SerialSettings(
        baudRate: m['baud'] as int? ?? 9600,
        dataBits: m['dataBits'] as int? ?? 8,
        parity: Parity.values.asNameMap()[m['parity']] ?? Parity.none,
        stopBits: m['stopBits'] as int? ?? 1,
      ),
      rtuTimeoutMs: m['rtuTimeoutMs'] as int? ?? d.rtuTimeoutMs,
      unitId: m['unitId'] as int? ?? d.unitId,
      addressOffset: m['addressOffset'] as int? ?? d.addressOffset,
      format: ValueFormat.values.asNameMap()[m['format']] ?? d.format,
    );
  }

  final TransportKind kind;
  final String host;
  final int port;
  final int tcpTimeoutMs;
  final String serialPort;
  final SerialSettings serial;
  final int rtuTimeoutMs;

  /// Slave / unit id, 0–247.
  final int unitId;

  /// Added to every address on the wire (e.g. -1 for devices that count from 1).
  final int addressOffset;
  final ValueFormat format;

  Duration get timeout => Duration(milliseconds: kind == TransportKind.tcp ? tcpTimeoutMs : rtuTimeoutMs);

  Map<String, Object> toMap() => {
    'kind': kind.name,
    'host': host,
    'port': port,
    'tcpTimeoutMs': tcpTimeoutMs,
    'serialPort': serialPort,
    'baud': serial.baudRate,
    'dataBits': serial.dataBits,
    'parity': serial.parity.name,
    'stopBits': serial.stopBits,
    'rtuTimeoutMs': rtuTimeoutMs,
    'unitId': unitId,
    'addressOffset': addressOffset,
    'format': format.name,
  };

  ModbusConfig copyWith({
    TransportKind? kind,
    String? host,
    int? port,
    int? tcpTimeoutMs,
    String? serialPort,
    SerialSettings? serial,
    int? rtuTimeoutMs,
    int? unitId,
    int? addressOffset,
    ValueFormat? format,
  }) => ModbusConfig(
    kind: kind ?? this.kind,
    host: host ?? this.host,
    port: port ?? this.port,
    tcpTimeoutMs: tcpTimeoutMs ?? this.tcpTimeoutMs,
    serialPort: serialPort ?? this.serialPort,
    serial: serial ?? this.serial,
    rtuTimeoutMs: rtuTimeoutMs ?? this.rtuTimeoutMs,
    unitId: unitId ?? this.unitId,
    addressOffset: addressOffset ?? this.addressOffset,
    format: format ?? this.format,
  );
}

/// A read definition: function, start address, quantity, scan rate.
class PollDef {
  const PollDef({
    required this.id,
    required this.name,
    this.func = Fc.readHoldingRegisters,
    this.address = 0,
    this.quantity = 10,
    this.intervalMs = 1000,
  });

  factory PollDef.fromMap(Map m) => PollDef(
    id: m['id'] as int,
    name: m['name'] as String,
    func: m['func'] as int? ?? Fc.readHoldingRegisters,
    address: m['address'] as int? ?? 0,
    quantity: m['quantity'] as int? ?? 10,
    intervalMs: m['intervalMs'] as int? ?? 1000,
  );

  final int id;
  final String name;
  final int func;
  final int address;
  final int quantity;
  final int intervalMs;

  bool get isBits => Fc.isBitRead(func);

  /// `FC03 · 0 · ×10 · 1000 ms`.
  String get summary => 'FC${func.toString().padLeft(2, '0')} · Addr $address · ×$quantity · $intervalMs ms';

  Map<String, Object> toMap() => {
    'id': id,
    'name': name,
    'func': func,
    'address': address,
    'quantity': quantity,
    'intervalMs': intervalMs,
  };

  PollDef copyWith({String? name, int? func, int? address, int? quantity, int? intervalMs}) => PollDef(
    id: id,
    name: name ?? this.name,
    func: func ?? this.func,
    address: address ?? this.address,
    quantity: quantity ?? this.quantity,
    intervalMs: intervalMs ?? this.intervalMs,
  );
}

/// A poll with its latest result.
class PollState {
  const PollState({
    required this.def,
    this.values = const [],
    this.error,
    this.lastAt,
    this.reads = 0,
    this.changed = const {},
  });

  final PollDef def;
  final List<int> values;

  /// Last error (exception, timeout); cleared by the next good read.
  final String? error;
  final DateTime? lastAt;
  final int reads;

  /// Indexes that changed in the last read (to highlight them).
  final Set<int> changed;

  PollState copyWith({
    PollDef? def,
    List<int>? values,
    String? error,
    bool clearError = false,
    DateTime? lastAt,
    int? reads,
    Set<int>? changed,
  }) => PollState(
    def: def ?? this.def,
    values: values ?? this.values,
    error: clearError ? null : (error ?? this.error),
    lastAt: lastAt ?? this.lastAt,
    reads: reads ?? this.reads,
    changed: changed ?? this.changed,
  );
}

enum LinkState { disconnected, connecting, connected }

class ModbusStats {
  const ModbusStats({this.requests = 0, this.errors = 0, this.lastMs = 0});

  final int requests;
  final int errors;
  final int lastMs;
}

enum LogKind { tx, rx, info, error }

class LogEntry {
  const LogEntry(this.at, this.kind, this.text);

  final DateTime at;
  final LogKind kind;
  final String text;

  String get tag => switch (kind) {
    LogKind.tx => 'TX',
    LogKind.rx => 'RX',
    LogKind.info => 'INF',
    LogKind.error => 'ERR',
  };
}
