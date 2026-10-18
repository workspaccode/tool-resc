import 'dart:typed_data';

/// Modbus function codes the tool uses.
abstract final class Fc {
  static const readCoils = 1;
  static const readDiscreteInputs = 2;
  static const readHoldingRegisters = 3;
  static const readInputRegisters = 4;
  static const writeSingleCoil = 5;
  static const writeSingleRegister = 6;
  static const writeMultipleCoils = 15;
  static const writeMultipleRegisters = 16;
  static const reportServerId = 17;

  static bool isBitRead(int fc) => fc == readCoils || fc == readDiscreteInputs;
  static bool isRead(int fc) => fc >= 1 && fc <= 4;

  static const readNames = {
    readCoils: '01 Read Coils (0x)',
    readDiscreteInputs: '02 Read Discrete Inputs (1x)',
    readHoldingRegisters: '03 Read Holding Registers (4x)',
    readInputRegisters: '04 Read Input Registers (3x)',
  };

  static const writeNames = {
    writeSingleCoil: '05 Write Single Coil',
    writeSingleRegister: '06 Write Single Register',
    writeMultipleCoils: '15 Write Multiple Coils',
    writeMultipleRegisters: '16 Write Multiple Registers',
  };
}

/// A Modbus exception response (function code | 0x80).
class ModbusException implements Exception {
  const ModbusException(this.function, this.code);

  final int function;
  final int code;

  static const names = {
    1: 'Illegal Function',
    2: 'Illegal Data Address',
    3: 'Illegal Data Value',
    4: 'Server Device Failure',
    5: 'Acknowledge',
    6: 'Server Device Busy',
    8: 'Memory Parity Error',
    10: 'Gateway Path Unavailable',
    11: 'Gateway Target Failed to Respond',
  };

  String get name => names[code] ?? 'Unknown';

  @override
  String toString() => 'Exception $code ($name)';
}

/// Builds request PDUs and reads response PDUs (function code + data, no
/// unit id, MBAP header or CRC).
abstract final class ModbusPdu {
  static Uint8List read(int fc, int address, int quantity) {
    _check16(address, 'address');
    if (quantity < 1 || quantity > (Fc.isBitRead(fc) ? 2000 : 125)) {
      throw ArgumentError('Quantity must be 1–${Fc.isBitRead(fc) ? 2000 : 125}');
    }
    return Uint8List.fromList([fc, address >> 8, address & 0xFF, quantity >> 8, quantity & 0xFF]);
  }

  static Uint8List writeSingleCoil(int address, bool on) {
    _check16(address, 'address');
    return Uint8List.fromList([Fc.writeSingleCoil, address >> 8, address & 0xFF, on ? 0xFF : 0x00, 0x00]);
  }

  static Uint8List writeSingleRegister(int address, int value) {
    _check16(address, 'address');
    final v = value & 0xFFFF;
    return Uint8List.fromList([Fc.writeSingleRegister, address >> 8, address & 0xFF, v >> 8, v & 0xFF]);
  }

  static Uint8List writeMultipleCoils(int address, List<bool> values) {
    _check16(address, 'address');
    if (values.isEmpty || values.length > 1968) throw ArgumentError('1–1968 coils');
    final bytes = Uint8List((values.length + 7) ~/ 8);
    for (var i = 0; i < values.length; i++) {
      if (values[i]) bytes[i ~/ 8] |= 1 << (i % 8);
    }
    final n = values.length;
    return Uint8List.fromList([
      Fc.writeMultipleCoils,
      address >> 8,
      address & 0xFF,
      n >> 8,
      n & 0xFF,
      bytes.length,
      ...bytes,
    ]);
  }

  static Uint8List writeMultipleRegisters(int address, List<int> values) {
    _check16(address, 'address');
    if (values.isEmpty || values.length > 123) throw ArgumentError('1–123 registers');
    final n = values.length;
    return Uint8List.fromList([
      Fc.writeMultipleRegisters,
      address >> 8,
      address & 0xFF,
      n >> 8,
      n & 0xFF,
      n * 2,
      for (final v in values) ...[(v >> 8) & 0xFF, v & 0xFF],
    ]);
  }

  /// Throws [ModbusException] for an exception response.
  static void checkException(Uint8List pdu) {
    if (pdu.isEmpty) throw const FormatException('Empty response');
    if (pdu[0] & 0x80 != 0) throw ModbusException(pdu[0] & 0x7F, pdu.length > 1 ? pdu[1] : 0);
  }

  /// Values of a read response: 16-bit registers, or 0/1 for coils and
  /// discrete inputs (only the [quantity] requested).
  static List<int> readValues(Uint8List pdu, int fc, int quantity) {
    checkException(pdu);
    if (pdu[0] != fc) throw FormatException('Response is for function ${pdu[0]}, not $fc');
    if (pdu.length < 2) throw const FormatException('Short response');
    final count = pdu[1];
    if (pdu.length < 2 + count) throw const FormatException('Response shorter than its byte count');
    final data = pdu.sublist(2, 2 + count);
    if (Fc.isBitRead(fc)) {
      return [for (var i = 0; i < quantity && i ~/ 8 < data.length; i++) (data[i ~/ 8] >> (i % 8)) & 1];
    }
    return [for (var i = 0; i + 1 < data.length; i += 2) (data[i] << 8) | data[i + 1]];
  }

  /// Bytes of an RTU response for this request, when it can be known from
  /// the request alone (null: unknown, wait for silence). Exception
  /// responses are always 5 bytes; see [rtuLengthSoFar].
  static int? expectedRtuLength(Uint8List requestPdu) {
    final fc = requestPdu[0];
    if (Fc.isRead(fc) && requestPdu.length >= 5) {
      final qty = (requestPdu[3] << 8) | requestPdu[4];
      final bytes = Fc.isBitRead(fc) ? (qty + 7) ~/ 8 : qty * 2;
      return 1 + 1 + 1 + bytes + 2; // unit, fc, count, data, crc
    }
    if (fc == Fc.writeSingleCoil ||
        fc == Fc.writeSingleRegister ||
        fc == Fc.writeMultipleCoils ||
        fc == Fc.writeMultipleRegisters) {
      return 8; // echo: unit, fc, addr(2), value/qty(2), crc
    }
    return null;
  }

  static void _check16(int v, String what) {
    if (v < 0 || v > 0xFFFF) throw ArgumentError('$what must be 0–65535');
  }
}

/// Modbus RTU CRC-16 (poly 0xA001, init 0xFFFF), low byte first on the wire.
int crc16(List<int> bytes, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  for (var i = start; i < (end ?? bytes.length); i++) {
    crc ^= bytes[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc;
}

/// RTU frame: unit id + PDU + CRC.
Uint8List rtuFrame(int unitId, Uint8List pdu) {
  final out = Uint8List(pdu.length + 3);
  out[0] = unitId;
  out.setRange(1, 1 + pdu.length, pdu);
  final crc = crc16(out, 0, pdu.length + 1);
  out[pdu.length + 1] = crc & 0xFF;
  out[pdu.length + 2] = crc >> 8;
  return out;
}

/// Checks an RTU response frame and returns its PDU.
Uint8List rtuPdu(Uint8List frame, int unitId) {
  if (frame.length < 5) {
    throw FormatException('No/short response (${frame.length} bytes). Check Unit ID, baud rate and parity.');
  }
  final rx = frame[frame.length - 2] | (frame[frame.length - 1] << 8);
  final calc = crc16(frame, 0, frame.length - 2);
  if (rx != calc) {
    throw FormatException(
      'CRC mismatch: got 0x${rx.toRadixString(16).padLeft(4, '0')}, expected 0x${calc.toRadixString(16).padLeft(4, '0')}',
    );
  }
  if (frame[0] != unitId) throw FormatException('Answer from unit ${frame[0]}, expected $unitId');
  return Uint8List.sublistView(frame, 1, frame.length - 2);
}

/// Modbus TCP frame: MBAP header (transaction, protocol 0, length, unit) + PDU.
Uint8List tcpFrame(int transactionId, int unitId, Uint8List pdu) {
  final len = pdu.length + 1;
  return Uint8List.fromList([transactionId >> 8, transactionId & 0xFF, 0, 0, len >> 8, len & 0xFF, unitId, ...pdu]);
}

/// `01 03 00 0A` style.
String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Parses `01 03 0x0A,FF` into bytes. Throws [FormatException] on bad input.
Uint8List parseHexBytes(String text) {
  final parts = text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty);
  return Uint8List.fromList([
    for (final p in parts)
      () {
        final v = int.tryParse(p.replaceFirst(RegExp('^0x', caseSensitive: false), ''), radix: 16);
        if (v == null || v < 0 || v > 0xFF) throw FormatException('“$p” is not a byte');
        return v;
      }(),
  ]);
}

/// Parses `123`, `-5` or `0x1F` (also `0b101`).
int? parseInt(String text) {
  final s = text.trim().toLowerCase();
  if (s.startsWith('0x')) return int.tryParse(s.substring(2), radix: 16);
  if (s.startsWith('0b')) return int.tryParse(s.substring(2), radix: 2);
  return int.tryParse(s);
}
