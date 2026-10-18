import 'dart:convert';

import 'protocol/modbus_codec.dart';

/// A known register of the inverter, from the Modbus Poll register library.
class RegisterPreset {
  const RegisterPreset({
    required this.category,
    required this.key,
    required this.name,
    required this.address,
    required this.count,
    required this.func,
    this.unit = '',
    this.description = '',
  });

  factory RegisterPreset.fromMap(Map m) => RegisterPreset(
    category: m['category'] as String,
    key: m['key'] as String,
    name: m['name'] as String,
    address: m['address'] as int,
    count: m['count'] as int? ?? 1,
    func: m['func'] as int? ?? Fc.readHoldingRegisters,
    unit: m['unit'] as String? ?? '',
    description: m['description'] as String? ?? '',
  );

  final String category;
  final String key;
  final String name;
  final int address;

  /// Registers it spans (2 for 32-bit values).
  final int count;

  /// 3 (holding) or 4 (input).
  final int func;
  final String unit;
  final String description;

  bool get isInput => func == Fc.readInputRegisters;

  /// e.g. "power_output" -> "Power Output".
  String get categoryLabel =>
      category.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  Map<String, Object> toMap() => {
    'category': category,
    'key': key,
    'name': name,
    'address': address,
    'count': count,
    'func': func,
    'unit': unit,
    'description': description,
  };

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty ||
        name.toLowerCase().contains(q) ||
        '$address'.contains(q) ||
        description.toLowerCase().contains(q) ||
        category.contains(q);
  }
}

/// Built-in register library (solar inverter map).
const builtInPresets = <RegisterPreset>[
  RegisterPreset(
    category: 'system_time',
    key: 'year',
    name: 'System Year',
    address: 4999,
    count: 1,
    func: 3,
    unit: '',
    description: 'System year (e.g., 2024)',
  ),
  RegisterPreset(
    category: 'system_time',
    key: 'month',
    name: 'System Month',
    address: 5000,
    count: 1,
    func: 3,
    unit: '',
    description: 'System month (1-12)',
  ),
  RegisterPreset(
    category: 'system_time',
    key: 'day',
    name: 'System Day',
    address: 5001,
    count: 1,
    func: 3,
    unit: '',
    description: 'System day (1-31)',
  ),
  RegisterPreset(
    category: 'system_time',
    key: 'hours',
    name: 'System Hours',
    address: 5002,
    count: 1,
    func: 3,
    unit: '',
    description: 'System hours (0-23)',
  ),
  RegisterPreset(
    category: 'system_time',
    key: 'minutes',
    name: 'System Minutes',
    address: 5003,
    count: 1,
    func: 3,
    unit: '',
    description: 'System minutes (0-59)',
  ),
  RegisterPreset(
    category: 'system_time',
    key: 'seconds',
    name: 'System Seconds',
    address: 5004,
    count: 1,
    func: 3,
    unit: '',
    description: 'System seconds (0-59)',
  ),
  RegisterPreset(
    category: 'device_control',
    key: 'boot_shutdown',
    name: 'Boot / Shutdown',
    address: 30029,
    count: 1,
    func: 3,
    unit: '',
    description: 'Boot/Shutdown control (206=Off, 207=On)',
  ),
  RegisterPreset(
    category: 'device_control',
    key: 'reset_state',
    name: 'Reset State',
    address: 30050,
    count: 1,
    func: 3,
    unit: '',
    description: 'Reset state (85=Normal, 170=Reset)',
  ),
  RegisterPreset(
    category: 'device_control',
    key: 'device_address',
    name: 'Modbus Device Address',
    address: 30459,
    count: 1,
    func: 3,
    unit: '',
    description: 'Modbus device address (1-247)',
  ),
  RegisterPreset(
    category: 'device_status',
    key: 'device_state',
    name: 'Device Operating State',
    address: 5037,
    count: 1,
    func: 4,
    unit: '',
    description: 'Operating state (0=Run, 0x8000=Stop)',
  ),
  RegisterPreset(
    category: 'device_status',
    key: 'fault_state',
    name: 'Fault Code',
    address: 5044,
    count: 1,
    func: 4,
    unit: '',
    description: 'Current fault code (0=No fault)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'real_time_power',
    name: 'Real-Time Power',
    address: 5030,
    count: 1,
    func: 4,
    unit: 'W',
    description: 'Real-time output power (0-36.3kW)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'total_dc_power',
    name: 'Total DC Power',
    address: 5016,
    count: 1,
    func: 4,
    unit: 'W',
    description: 'Total DC input power (0-36.3kW)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'active_power',
    name: 'Active Power Output',
    address: 5231,
    count: 1,
    func: 4,
    unit: 'W',
    description: 'Active power output (0-36.3kW)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'reactive_power',
    name: 'Reactive Power Output',
    address: 5233,
    count: 1,
    func: 4,
    unit: 'VAR',
    description: 'Reactive power (-36.3k to +36.3kVAR)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'apparent_power',
    name: 'Apparent Power Output',
    address: 5237,
    count: 1,
    func: 4,
    unit: 'VA',
    description: 'Apparent power output (0-36.3kVA)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'power_factor',
    name: 'Power Factor',
    address: 5240,
    count: 1,
    func: 4,
    unit: 'scale 0.001',
    description: 'Power factor (0.000 to 1.000)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'frequency',
    name: 'Grid Frequency',
    address: 5241,
    count: 1,
    func: 4,
    unit: 'Hz x 0.01',
    description: 'Grid frequency (45-65Hz)',
  ),
  RegisterPreset(
    category: 'power_output',
    key: 'bus_voltage',
    name: 'Bus Voltage',
    address: 5243,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'Bus voltage (312-480V)',
  ),
  RegisterPreset(
    category: 'yield_data',
    key: 'yield_today',
    name: 'Yield Today',
    address: 5002,
    count: 1,
    func: 4,
    unit: 'kWh x 0.1',
    description: 'Energy yield today',
  ),
  RegisterPreset(
    category: 'yield_data',
    key: 'yield_total',
    name: 'Total Cumulative Yield',
    address: 5003,
    count: 2,
    func: 4,
    unit: 'kWh',
    description: 'Total cumulative energy yield',
  ),
  RegisterPreset(
    category: 'yield_data',
    key: 'yield_month',
    name: 'Yield This Month',
    address: 5223,
    count: 1,
    func: 4,
    unit: 'kWh x 0.1',
    description: 'Energy yield this month',
  ),
  RegisterPreset(
    category: 'yield_data',
    key: 'yield_year',
    name: 'Yield This Year',
    address: 5225,
    count: 1,
    func: 4,
    unit: 'kWh x 0.1',
    description: 'Energy yield this year',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_a_voltage',
    name: 'Phase A Voltage',
    address: 5246,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'Phase A voltage',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_b_voltage',
    name: 'Phase B Voltage',
    address: 5247,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'Phase B voltage',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_c_voltage',
    name: 'Phase C Voltage',
    address: 5248,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'Phase C voltage',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_a_current',
    name: 'Phase A Current',
    address: 5249,
    count: 1,
    func: 4,
    unit: 'A x 0.1',
    description: 'Phase A current',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_b_current',
    name: 'Phase B Current',
    address: 5250,
    count: 1,
    func: 4,
    unit: 'A x 0.1',
    description: 'Phase B current',
  ),
  RegisterPreset(
    category: 'grid_phase',
    key: 'phase_c_current',
    name: 'Phase C Current',
    address: 5251,
    count: 1,
    func: 4,
    unit: 'A x 0.1',
    description: 'Phase C current',
  ),
  RegisterPreset(
    category: 'pv_strings',
    key: 'pv1_voltage',
    name: 'PV String 1 Voltage',
    address: 5252,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'PV1 Voltage',
  ),
  RegisterPreset(
    category: 'pv_strings',
    key: 'pv1_current',
    name: 'PV String 1 Current',
    address: 5253,
    count: 1,
    func: 4,
    unit: 'A x 0.01',
    description: 'PV1 Current',
  ),
  RegisterPreset(
    category: 'pv_strings',
    key: 'pv2_voltage',
    name: 'PV String 2 Voltage',
    address: 5254,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'PV2 Voltage',
  ),
  RegisterPreset(
    category: 'pv_strings',
    key: 'pv2_current',
    name: 'PV String 2 Current',
    address: 5255,
    count: 1,
    func: 4,
    unit: 'A x 0.01',
    description: 'PV2 Current',
  ),
  RegisterPreset(
    category: 'mppt',
    key: 'mppt1_voltage',
    name: 'MPPT 1 Voltage',
    address: 5332,
    count: 1,
    func: 4,
    unit: 'V x 0.1',
    description: 'MPPT 1 Voltage',
  ),
  RegisterPreset(
    category: 'mppt',
    key: 'mppt1_current',
    name: 'MPPT 1 Current',
    address: 5333,
    count: 1,
    func: 4,
    unit: 'A x 0.1',
    description: 'MPPT 1 Current',
  ),
  RegisterPreset(
    category: 'power_limits',
    key: 'active_power_limit',
    name: 'Active Power Limit',
    address: 32253,
    count: 1,
    func: 3,
    unit: 'kW x 0.1',
    description: 'Active power limit setting',
  ),
  RegisterPreset(
    category: 'power_limits',
    key: 'apparent_power_limit',
    name: 'Apparent Power Limit',
    address: 32259,
    count: 1,
    func: 3,
    unit: 'kVA x 0.1',
    description: 'Apparent power limit setting',
  ),
  RegisterPreset(
    category: 'grid_protection',
    key: 'protection_level',
    name: 'Protection Level',
    address: 32312,
    count: 1,
    func: 3,
    unit: '',
    description: 'Protection level (0=L1, 1=L2, 2=L3, 3=L4, 4=L5)',
  ),
  RegisterPreset(
    category: 'grid_protection',
    key: 'undervoltage_level1_value',
    name: 'Undervoltage L1 Value',
    address: 32321,
    count: 1,
    func: 3,
    unit: 'V x 0.1',
    description: 'Undervoltage L1 value',
  ),
  RegisterPreset(
    category: 'grid_protection',
    key: 'overvoltage_level1_value',
    name: 'Overvoltage L1 Value',
    address: 32322,
    count: 1,
    func: 3,
    unit: 'V x 0.1',
    description: 'Overvoltage L1 value',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_1',
    name: 'Overfrequency Reduction 1',
    address: 31399,
    count: 1,
    func: 3,
    unit: '',
    description: 'Over frequency derating',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_F1',
    name: 'Overfrequency Reduction F1',
    address: 31403,
    count: 1,
    func: 3,
    unit: 'Hz x 0.01',
    description: 'Over frequency derating F1',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_F2',
    name: 'Overfrequency Reduction F2',
    address: 31404,
    count: 1,
    func: 3,
    unit: 'Hz x 0.01',
    description: 'Over frequency derating F2',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_F3',
    name: 'Overfrequency Reduction F3',
    address: 31405,
    count: 1,
    func: 3,
    unit: 'Hz x 0.01',
    description: 'Over frequency derating F3',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_P1',
    name: 'Overfrequency Reduction P1',
    address: 31408,
    count: 1,
    func: 3,
    unit: 'kW x 0.1',
    description: 'Over frequency derating P1',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_P2',
    name: 'Overfrequency Reduction P2',
    address: 31410,
    count: 1,
    func: 3,
    unit: 'kW x 0.1',
    description: 'Over frequency derating P2',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'reduction_P3',
    name: 'Overfrequency Reduction P3',
    address: 31411,
    count: 1,
    func: 3,
    unit: 'kW x 0.1',
    description: 'Over frequency derating P3',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'derating_recovery_point',
    name: 'Overfrequency Derating Recovery Point',
    address: 31412,
    count: 1,
    func: 3,
    unit: 'Hz x 0.01',
    description: 'Overfrequency derating recovery point',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'derating_curve',
    name: 'Overfrequency Derating Curve',
    address: 31413,
    count: 1,
    func: 3,
    unit: '',
    description: 'Overfrequency derating curve',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'active_power_decrease_rate',
    name: 'Active Power Decrease Rate',
    address: 31414,
    count: 1,
    func: 3,
    unit: '',
    description: 'The rate of derating when overfrequency derating is performed',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'recovery_wait_time',
    name: 'Recovery Wait Time',
    address: 31415,
    count: 1,
    func: 3,
    unit: 's x 0.1',
    description: 'Wait for recovery time after overfrequency derating',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'active_recovery_rate',
    name: 'Active Recovery Rate',
    address: 31416,
    count: 1,
    func: 3,
    unit: '',
    description: 'Active recovery rate after overfrequency derating',
  ),
  RegisterPreset(
    category: 'overfrequency_reduction',
    key: 'derating_response_time',
    name: 'Overfrequency Derating Response Time',
    address: 31417,
    count: 1,
    func: 3,
    unit: 's x 0.01',
    description: 'Overfrequency derating response time (derating delay)',
  ),
];

/// Parses a custom register map: JSON `{category: {key: {address, count,
/// register_type, unit, description}}}`, or the Python form
/// `REGISTER_DEFINITIONS = {...}` with `#` comments.
List<RegisterPreset> parseRegisterJson(String text) {
  var raw = text.trim();
  if (raw.contains('REGISTER_DEFINITIONS')) {
    raw = raw.replaceFirst(RegExp(r'^[\s\S]*?REGISTER_DEFINITIONS\s*=\s*'), '');
  }
  raw = raw
      .replaceAll(RegExp(r'#.*$', multiLine: true), '')
      .replaceAll(RegExp(r'True'), 'true')
      .replaceAll(RegExp(r'False'), 'false')
      .replaceAll(RegExp(r'None'), 'null')
      .replaceAll("'", '"')
      .replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!); // trailing commas
  final parsed = jsonDecode(raw);
  if (parsed is! Map) throw const FormatException('Expected an object of categories');
  final out = <RegisterPreset>[];
  for (final MapEntry(key: category, value: regs) in parsed.entries) {
    if (regs is! Map) continue;
    for (final MapEntry(key: key, value: reg) in regs.entries) {
      if (reg is! Map || reg['address'] is! num) continue;
      final type = '${reg['register_type'] ?? 'holding'}'.toLowerCase();
      out.add(
        RegisterPreset(
          category: '$category',
          key: '$key',
          name: '$key'.replaceAll('_', ' ').toUpperCase(),
          address: (reg['address'] as num).toInt(),
          count: (reg['count'] as num?)?.toInt() ?? 1,
          func: type == 'input' ? Fc.readInputRegisters : Fc.readHoldingRegisters,
          unit: '${reg['unit'] ?? ''}',
          description: '${reg['description'] ?? ''}',
        ),
      );
    }
  }
  return out;
}
