import 'dart:typed_data';

/// How register values are shown, like Modbus Poll's Display menu.
enum ValueFormat {
  signed('Signed', 1),
  unsigned('Unsigned', 1),
  hex('Hex', 1),
  binary('Binary', 1),
  int32('Int32 (AB CD)', 2),
  uint32('UInt32 (AB CD)', 2),
  int32Swapped('Int32 (CD AB)', 2),
  float32('Float (AB CD)', 2),
  float32Swapped('Float (CD AB)', 2);

  const ValueFormat(this.label, this.registers);

  final String label;

  /// Registers one value takes.
  final int registers;
}

/// Formats [values] at [index] (a register value, or 0/1 for bits).
String formatValue(List<int> values, int index, ValueFormat format, {bool bits = false}) {
  if (index >= values.length) return '-';
  final v = values[index] & 0xFFFF;
  if (bits) return '${values[index]}';
  switch (format) {
    case ValueFormat.signed:
      return '${v > 0x7FFF ? v - 0x10000 : v}';
    case ValueFormat.unsigned:
      return '$v';
    case ValueFormat.hex:
      return hex16(v);
    case ValueFormat.binary:
      final b = v.toRadixString(2).padLeft(16, '0');
      return '${b.substring(0, 4)} ${b.substring(4, 8)} ${b.substring(8, 12)} ${b.substring(12)}';
    case ValueFormat.int32 ||
        ValueFormat.uint32 ||
        ValueFormat.int32Swapped ||
        ValueFormat.float32 ||
        ValueFormat.float32Swapped:
      if (index + 1 >= values.length) return '-';
      final swapped = format == ValueFormat.int32Swapped || format == ValueFormat.float32Swapped;
      final hi = swapped ? values[index + 1] : values[index];
      final lo = swapped ? values[index] : values[index + 1];
      final data = ByteData(4)
        ..setUint16(0, hi & 0xFFFF)
        ..setUint16(2, lo & 0xFFFF);
      return switch (format) {
        ValueFormat.uint32 => '${data.getUint32(0)}',
        ValueFormat.float32 || ValueFormat.float32Swapped => _float(data.getFloat32(0)),
        _ => '${data.getInt32(0)}',
      };
  }
}

String hex16(int v) => '0x${(v & 0xFFFF).toRadixString(16).padLeft(4, '0').toUpperCase()}';

String bin16(int v) => (v & 0xFFFF).toRadixString(2).padLeft(16, '0');

String _float(double f) {
  if (f.isNaN || f.isInfinite) return '$f';
  return f.abs() >= 1e7 || (f != 0 && f.abs() < 1e-4) ? f.toStringAsExponential(4) : f.toStringAsFixed(4);
}
