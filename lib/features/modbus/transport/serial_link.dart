import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart' as sp;
import 'package:usb_serial/usb_serial.dart';

enum Parity { none, even, odd }

/// Serial line settings, e.g. 9600 8N1.
class SerialSettings {
  const SerialSettings({this.baudRate = 9600, this.dataBits = 8, this.parity = Parity.none, this.stopBits = 1});

  final int baudRate;
  final int dataBits;
  final Parity parity;
  final int stopBits;

  /// `9600 8N1`.
  String get label => '$baudRate $dataBits${parity.name[0].toUpperCase()}$stopBits';
}

/// A serial port the user can pick.
class SerialPortInfo {
  const SerialPortInfo({required this.id, required this.label});

  /// Port name (`COM3`, `/dev/ttyUSB0`) or Android USB device id.
  final String id;
  final String label;
}

/// A byte pipe to a serial device. Platform implementations below.
abstract class SerialLink {
  String get label;
  Stream<Uint8List> get input;
  Future<void> open();
  Future<void> write(Uint8List bytes);
  Future<void> close();

  /// Serial ports are supported on desktop (libserialport) and Android (USB
  /// OTG adapters: FTDI, CP210x, CH34x, PL2303, CDC). Not on iOS.
  static bool get isSupported => Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isAndroid;

  static Future<List<SerialPortInfo>> listPorts() async {
    if (Platform.isAndroid) {
      return [
        for (final d in await UsbSerial.listDevices())
          SerialPortInfo(
            id: '${d.deviceId}',
            label: [d.productName ?? 'USB Serial', if (d.manufacturerName != null) d.manufacturerName!].join(' · '),
          ),
      ];
    }
    if (!isSupported) return const [];
    return [for (final name in sp.SerialPort.availablePorts) SerialPortInfo(id: name, label: _describe(name))];
  }

  static SerialLink create(String portId, SerialSettings settings) =>
      Platform.isAndroid ? _UsbLink(portId, settings) : _DesktopLink(portId, settings);

  static String _describe(String name) {
    final port = sp.SerialPort(name);
    try {
      final d = port.description;
      return d == null || d.isEmpty || d == name ? name : '$name — $d';
    } catch (_) {
      return name;
    } finally {
      port.dispose();
    }
  }
}

/// Windows, macOS, Linux via libserialport.
class _DesktopLink implements SerialLink {
  _DesktopLink(this.name, this.settings);

  final String name;
  final SerialSettings settings;
  sp.SerialPort? _port;
  sp.SerialPortReader? _reader;

  @override
  String get label => '$name ${settings.label}';

  @override
  Stream<Uint8List> get input => _reader!.stream;

  @override
  Future<void> open() async {
    final port = sp.SerialPort(name);
    if (!port.openReadWrite()) {
      final err = sp.SerialPort.lastError;
      port.dispose();
      throw StateError('Can’t open $name: ${err?.message ?? 'busy or not found'}');
    }
    final config = sp.SerialPortConfig()
      ..baudRate = settings.baudRate
      ..bits = settings.dataBits
      ..stopBits = settings.stopBits
      ..parity = switch (settings.parity) {
        Parity.none => sp.SerialPortParity.none,
        Parity.even => sp.SerialPortParity.even,
        Parity.odd => sp.SerialPortParity.odd,
      }
      ..setFlowControl(sp.SerialPortFlowControl.none);
    port.config = config;
    config.dispose();
    _port = port;
    _reader = sp.SerialPortReader(port, timeout: 10);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final port = _port;
    if (port == null) throw StateError('Serial port is not open');
    port.write(bytes, timeout: 1000);
  }

  @override
  Future<void> close() async {
    _reader?.close();
    _reader = null;
    _port?.close();
    _port?.dispose();
    _port = null;
  }
}

/// Android via USB OTG.
class _UsbLink implements SerialLink {
  _UsbLink(this.deviceId, this.settings);

  final String deviceId;
  final SerialSettings settings;
  UsbPort? _port;
  String _name = 'USB';

  @override
  String get label => '$_name ${settings.label}';

  @override
  Stream<Uint8List> get input => _port!.inputStream!;

  @override
  Future<void> open() async {
    final devices = await UsbSerial.listDevices();
    final device = devices.where((d) => '${d.deviceId}' == deviceId).firstOrNull;
    if (device == null) throw StateError('USB adapter not found. Plug it in and pick it again.');
    final port = await device.create(); // asks for USB permission the first time
    if (port == null || !await port.open()) throw StateError('Can’t open the USB adapter (permission denied?)');
    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(
      settings.baudRate,
      settings.dataBits,
      settings.stopBits == 2 ? UsbPort.STOPBITS_2 : UsbPort.STOPBITS_1,
      switch (settings.parity) {
        Parity.none => UsbPort.PARITY_NONE,
        Parity.even => UsbPort.PARITY_EVEN,
        Parity.odd => UsbPort.PARITY_ODD,
      },
    );
    _name = device.productName ?? 'USB';
    _port = port;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final port = _port;
    if (port == null) throw StateError('Serial port is not open');
    await port.write(bytes);
  }

  @override
  Future<void> close() async {
    await _port?.close();
    _port = null;
  }
}
