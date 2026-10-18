import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/modbus/cloud/cloud_link.dart';
import 'package:tool_resc/features/modbus/modbus_controller.dart';
import 'package:tool_resc/features/modbus/modbus_models.dart';
import 'package:tool_resc/features/modbus/presets.dart';
import 'package:tool_resc/features/modbus/protocol/modbus_codec.dart';
import 'package:tool_resc/features/modbus/protocol/value_format.dart';
import 'package:tool_resc/features/modbus/transport/modbus_transport.dart';
import 'package:tool_resc/features/modbus/transport/rtu_transport.dart';
import 'package:tool_resc/features/modbus/transport/serial_link.dart';
import 'package:tool_resc/features/modbus/transport/tcp_transport.dart';

/// A tiny Modbus device: answers PDUs from 10 000 holding/input registers
/// and coils, like mock-inverter.js.
class FakeDevice {
  final registers = List<int>.filled(10000, 0);
  final coils = List<int>.filled(10000, 0);

  Uint8List answer(Uint8List pdu) {
    final fc = pdu[0];
    int u16(int i) => (pdu[i] << 8) | pdu[i + 1];
    switch (fc) {
      case 1 || 2:
        final a = u16(1), n = u16(3);
        final bytes = Uint8List((n + 7) ~/ 8);
        for (var i = 0; i < n; i++) {
          if (coils[a + i] != 0) bytes[i ~/ 8] |= 1 << (i % 8);
        }
        return Uint8List.fromList([fc, bytes.length, ...bytes]);
      case 3 || 4:
        final a = u16(1), n = u16(3);
        if (a + n > registers.length) return Uint8List.fromList([fc | 0x80, 2]);
        return Uint8List.fromList([
          fc,
          n * 2,
          for (var i = 0; i < n; i++) ...[registers[a + i] >> 8, registers[a + i] & 0xFF],
        ]);
      case 5:
        coils[u16(1)] = pdu[3] == 0xFF ? 1 : 0;
        return pdu;
      case 6:
        registers[u16(1)] = u16(3);
        return pdu;
      case 16:
        final a = u16(1), n = u16(3);
        for (var i = 0; i < n; i++) {
          registers[a + i] = (pdu[6 + i * 2] << 8) | pdu[7 + i * 2];
        }
        return Uint8List.sublistView(pdu, 0, 5);
    }
    return Uint8List.fromList([fc | 0x80, 1]);
  }
}

/// Serves [device] over Modbus TCP. Sends answers split in two pieces to
/// check the client reassembles frames.
Future<ServerSocket> serveTcp(FakeDevice device) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    var buf = <int>[];
    client.listen((data) async {
      buf.addAll(data);
      while (buf.length >= 7) {
        final total = 6 + ((buf[4] << 8) | buf[5]);
        if (buf.length < total) break;
        final frame = buf.sublist(0, total);
        buf = buf.sublist(total);
        final resp = device.answer(Uint8List.fromList(frame.sublist(7)));
        final out = tcpFrame((frame[0] << 8) | frame[1], frame[6], resp);
        client.add(out.sublist(0, 3));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        client.add(out.sublist(3));
      }
    });
  });
  return server;
}

/// A serial line wired to [device] as unit [unit], answering RTU frames.
class FakeSerial implements SerialLink {
  FakeSerial(this.device, {this.unit = 1});

  final FakeDevice device;
  final int unit;
  final _in = StreamController<Uint8List>();

  @override
  String get label => 'FAKE 9600 8N1';

  @override
  Stream<Uint8List> get input => _in.stream;

  @override
  Future<void> open() async {}

  @override
  Future<void> write(Uint8List bytes) async {
    if (bytes[0] != unit) return; // another unit: silence
    final pdu = rtuPdu(bytes, unit);
    final resp = rtuFrame(unit, device.answer(Uint8List.fromList(pdu)));
    // Arrives in pieces, like a real UART.
    Timer(const Duration(milliseconds: 3), () => _in.add(resp.sublist(0, 2)));
    Timer(const Duration(milliseconds: 8), () => _in.add(resp.sublist(2)));
  }

  @override
  Future<void> close() => _in.close();
}

/// The cloud backend's /ingest endpoint: collects the messages.
Future<(HttpServer, List<Map>)> serveCloud() async {
  final got = <Map>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (req.uri.path != '/ingest') {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.listen((raw) {
      final m = jsonDecode(raw as String) as Map;
      got.add(m);
      if (m['type'] == 'hello') ws.add(jsonEncode({'type': 'ack', 'message': 'Gateway registered'}));
    });
  });
  return (server, got);
}

Future<void> waitFor(bool Function() ok, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('codec', () {
    test('CRC and RTU framing match the Modbus spec example', () {
      final frame = rtuFrame(1, ModbusPdu.read(3, 0, 10));
      expect(toHex(frame), '01 03 00 00 00 0A C5 CD');
      expect(rtuPdu(frame, 1), [3, 0, 0, 0, 10]);
      frame[3] ^= 1;
      expect(() => rtuPdu(frame, 1), throwsFormatException);
    });

    test('read responses: registers, bits, exceptions', () {
      expect(ModbusPdu.readValues(Uint8List.fromList([3, 4, 0x01, 0x02, 0xFF, 0xFF]), 3, 2), [0x0102, 0xFFFF]);
      expect(ModbusPdu.readValues(Uint8List.fromList([1, 2, 0x05, 0x01]), 1, 10), [1, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
      expect(
        () => ModbusPdu.readValues(Uint8List.fromList([0x83, 2]), 3, 1),
        throwsA(isA<ModbusException>().having((e) => e.name, 'name', 'Illegal Data Address')),
      );
      expect(ModbusPdu.expectedRtuLength(ModbusPdu.read(3, 0, 10)), 25);
      expect(ModbusPdu.expectedRtuLength(ModbusPdu.writeSingleRegister(1, 2)), 8);
    });

    test('write PDUs', () {
      expect(toHex(ModbusPdu.writeSingleCoil(0x13, true)), '05 00 13 FF 00');
      expect(
        toHex(ModbusPdu.writeMultipleCoils(0x13, [true, false, true, true, false, false, true, true, true, false])),
        '0F 00 13 00 0A 02 CD 01',
      );
      expect(toHex(ModbusPdu.writeMultipleRegisters(1, [0x000A, 0x0102])), '10 00 01 00 02 04 00 0A 01 02');
      expect(parseHexBytes('00 0A,0x1f'), [0, 10, 31]);
      expect(parseInt('0x1F'), 31);
      expect(parseInt('-5'), -5);
    });

    test('display formats', () {
      final v = [0x4120, 0x0000, 0xFFFF];
      expect(formatValue(v, 2, ValueFormat.signed), '-1');
      expect(formatValue(v, 2, ValueFormat.unsigned), '65535');
      expect(formatValue(v, 0, ValueFormat.hex), '0x4120');
      expect(formatValue(v, 0, ValueFormat.binary), '0100 0001 0010 0000');
      expect(formatValue(v, 0, ValueFormat.float32), '10.0000');
      expect(formatValue([0x0000, 0x4120], 0, ValueFormat.float32Swapped), '10.0000');
      expect(formatValue([0xFFFF, 0xFFFE], 0, ValueFormat.int32), '-2');
      expect(formatValue([0x0001, 0x0000], 0, ValueFormat.int32Swapped), '1');
      expect(formatValue(v, 2, ValueFormat.float32), '-');
    });

    test('custom register maps, JSON or Python', () {
      final presets = parseRegisterJson('''
REGISTER_DEFINITIONS = {
  # comment
  'battery': {
    'soc': {'address': 13022, 'count': 1, 'register_type': 'input', 'unit': '%', 'description': 'State of charge'},
    'bad': {'count': 1},
  },
}''');
      expect(presets, hasLength(1));
      expect(presets.single.address, 13022);
      expect(presets.single.func, Fc.readInputRegisters);
      expect(builtInPresets.where((p) => p.key == 'real_time_power').single.address, 5030);
    });
  });

  group('transports', () {
    test('TCP: requests, split frames, exceptions', () async {
      final device = FakeDevice()..registers[100] = 1234;
      final server = await serveTcp(device);
      addTearDown(server.close);
      final t = TcpTransport(host: '127.0.0.1', port: server.port);
      final frames = <String>[];
      t.onFrame = (tx, f) => frames.add('${tx ? 'TX' : 'RX'} ${toHex(f)}');
      await t.open();
      addTearDown(t.close);

      final results = await Future.wait([
        for (var i = 0; i < 5; i++) t.request(1, ModbusPdu.read(3, 100, 1), timeout: const Duration(seconds: 2)),
      ]);
      for (final r in results) {
        expect(ModbusPdu.readValues(r, 3, 1), [1234]);
      }
      expect(frames.first, startsWith('TX 00 01 00 00 00 06 01 03 00 64 00 01'));
      final exc = await t.request(1, ModbusPdu.read(3, 9999, 5), timeout: const Duration(seconds: 2));
      expect(() => ModbusPdu.checkException(exc), throwsA(isA<ModbusException>()));
    });

    test('TCP: timeout when nobody answers', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((_) {});
      final t = TcpTransport(host: '127.0.0.1', port: server.port);
      await t.open();
      addTearDown(t.close);
      expect(
        () => t.request(1, ModbusPdu.read(3, 0, 1), timeout: const Duration(milliseconds: 100)),
        throwsA(isA<ModbusTimeout>()),
      );
    });

    test('RTU: framed answers, wrong unit times out', () async {
      final device = FakeDevice()..registers[5030] = 24513;
      final t = RtuTransport(FakeSerial(device, unit: 1));
      await t.open();
      addTearDown(t.close);
      final r = await t.request(1, ModbusPdu.read(4, 5030, 1), timeout: const Duration(seconds: 1));
      expect(ModbusPdu.readValues(r, 4, 1), [24513]);
      await t.request(1, ModbusPdu.writeSingleRegister(7, 99), timeout: const Duration(seconds: 1));
      expect(device.registers[7], 99);
      expect(
        () => t.request(2, ModbusPdu.read(3, 0, 1), timeout: const Duration(milliseconds: 150)),
        throwsA(isA<ModbusTimeout>()),
      );
    });
  });

  test('cloud URLs resolve to /ingest and /data', () {
    expect(const CloudConfig(url: 'ws://host:8790').ingestUri.toString(), 'ws://host:8790/ingest');
    expect(const CloudConfig(url: 'ws://host:8790/ingest/').ingestUri.toString(), 'ws://host:8790/ingest');
    expect(const CloudConfig(url: 'https://cloud.example.com').ingestUri.toString(), 'wss://cloud.example.com/ingest');
    expect(const CloudConfig(url: '10.0.0.2:8790').feedUri.toString(), 'ws://10.0.0.2:8790/data');
  });

  group('controller', () {
    late ProviderContainer app;
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('modbus_test');
      await initStorage(path: dir.path);
      app = ProviderContainer();
      app.listen(modbusProvider, (_, _) {});
    });

    tearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    ModbusController modbus() => app.read(modbusProvider.notifier);
    ModbusState state() => app.read(modbusProvider);

    test('polls a device, writes, and uploads every reading to the cloud', () async {
      final device = FakeDevice()
        ..registers[5030] = 24513
        ..registers[5031] = 7;
      final tcp = await serveTcp(device);
      final (cloud, got) = await serveCloud();
      addTearDown(() async {
        await tcp.close();
        await cloud.close(force: true);
      });

      modbus().updateCloud(
        (c) => c.copyWith(enabled: true, url: 'ws://127.0.0.1:${cloud.port}', site: 'SITE-7', device: 'INV-2'),
      );
      await waitFor(() => state().cloudState == CloudState.live && got.isNotEmpty);
      expect(got.first, containsPair('type', 'hello'));
      expect(got.first, containsPair('site', 'SITE-7'));

      modbus().updateConfig((c) => c.copyWith(host: '127.0.0.1', port: tcp.port, unitId: 3));
      modbus().savePoll(const PollDef(id: 0, name: 'Power', func: 4, address: 5030, quantity: 2, intervalMs: 50));
      await modbus().connect();
      expect(state().polling, isTrue, reason: 'polling starts on connect');

      await waitFor(() => state().polls.single.values.isNotEmpty);
      expect(state().polls.single.values, [24513, 7]);
      await waitFor(() => got.any((m) => m['type'] == 'reading'));
      final reading = got.firstWhere((m) => m['type'] == 'reading');
      expect(reading['name'], 'Power');
      expect(reading['func'], 4);
      expect(reading['addr'], 5030);
      expect(reading['values'], [24513, 7]);
      expect(reading['unitId'], '3');
      expect(reading['device'], 'INV-2');

      // The chart follows the first register.
      await waitFor(() => state().trend.length >= 2);
      expect(state().trend.last, 24513);

      // Writes reach the device and the next poll shows them.
      await modbus().write(Fc.writeMultipleRegisters, 5030, [100, 200]);
      await waitFor(() => state().polls.single.values.first == 100);
      expect(device.registers[5031], 200);
      expect(state().stats.requests, greaterThan(2));
      expect(modbus().exportCsv(), contains('"Power",4,5030,100,0x0064'));

      // Settings and polls survive a restart.
      await modbus().disconnect();
      expect(state().link, LinkState.disconnected);
      app.dispose();
      app = ProviderContainer()..listen(modbusProvider, (_, _) {});
      expect(state().polls.single.def.address, 5030);
      expect(state().config.unitId, 3);
      expect(state().cloud.site, 'SITE-7');
    });

    test('Cloud Share turned on right at startup stays linked', () async {
      final (cloud, got) = await serveCloud();
      addTearDown(() => cloud.close(force: true));
      app.dispose();
      app = ProviderContainer()..listen(modbusProvider, (_, _) {});
      // Same tick as the controller's start-up auto-link.
      modbus().updateCloud((c) => c.copyWith(enabled: true, url: 'ws://127.0.0.1:${cloud.port}'));
      await waitFor(() => got.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(state().cloudState, CloudState.live);
    });

    test('scanner finds the units that answer', () async {
      final device = FakeDevice();
      final tcp = await serveTcp(device);
      addTearDown(tcp.close);
      modbus().updateConfig((c) => c.copyWith(host: '127.0.0.1', port: tcp.port));
      await modbus().connect();
      final results = await modbus().scan(from: 1, to: 3, fc: 3, address: 0).toList();
      expect(results.map((r) => r.unit), [1, 2, 3]);
      expect(results.every((r) => r.found), isTrue); // the fake answers every unit
    });

    test('connecting to nothing fails cleanly', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close();
      modbus().updateConfig((c) => c.copyWith(host: '127.0.0.1', port: port));
      await expectLater(modbus().connect(), throwsA(isA<SocketException>()));
      expect(state().link, LinkState.disconnected);
    });
  });
}
