import 'dart:async';
import 'dart:typed_data';

import '../protocol/modbus_codec.dart';
import 'modbus_transport.dart';
import 'serial_link.dart';

/// Modbus RTU over a serial port (RS485/RS232 adapter).
///
/// A response is complete when it has the length the request implies (or
/// the 5 bytes of an exception), or when the line has been silent for
/// [silence] after some bytes arrived — for function codes whose length
/// isn't known up front.
class RtuTransport extends ModbusTransport {
  RtuTransport(this.link, {this.silence = const Duration(milliseconds: 50)});

  final SerialLink link;
  final Duration silence;

  final _queue = SerialQueue();
  final _rx = BytesBuilder();
  final _done = Completer<void>();
  StreamSubscription<Uint8List>? _sub;
  void Function()? _onBytes;

  @override
  String get label => 'RTU ${link.label}';

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> open() async {
    await link.open();
    _sub = link.input.listen(
      (data) {
        _rx.add(data);
        _onBytes?.call();
      },
      onError: (_) => _drop(),
      onDone: _drop,
    );
  }

  @override
  Future<Uint8List> request(int unitId, Uint8List pdu, {required Duration timeout}) => _queue.run(() async {
    if (_sub == null) throw StateError('Serial port is not open');
    _rx.clear(); // drop line noise and late answers to earlier requests
    final frame = rtuFrame(unitId, pdu);
    final expected = ModbusPdu.expectedRtuLength(pdu);
    onFrame?.call(true, frame);
    await link.write(frame);

    final deadline = DateTime.now().add(timeout);
    final answer = await _collect(expected, deadline, unitId == 0);
    if (unitId == 0) return pdu; // broadcast: nobody answers; treat as accepted
    if (answer.isEmpty) throw ModbusTimeout(timeout);
    onFrame?.call(false, answer);
    return rtuPdu(answer, unitId);
  });

  /// Waits for a whole response frame. Broadcast (unit 0) has no answer.
  Future<Uint8List> _collect(int? expected, DateTime deadline, bool broadcast) async {
    if (broadcast) {
      await Future<void>.delayed(silence * 2);
      return Uint8List(0);
    }
    Timer? silenceTimer;
    Timer? deadlineTimer;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    bool complete() {
      final n = _rx.length;
      if (n >= 5) {
        final head = _rx.toBytes();
        if (head[1] & 0x80 != 0) return true; // exception: unit, fc, code, crc(2)
      }
      return expected != null && n >= expected;
    }

    _onBytes = () {
      if (complete()) return finish();
      silenceTimer?.cancel();
      silenceTimer = Timer(silence, finish);
    };
    final left = deadline.difference(DateTime.now());
    deadlineTimer = Timer(left.isNegative ? Duration.zero : left, finish);
    if (_rx.length > 0) _onBytes!();

    await done.future;
    _onBytes = null;
    silenceTimer?.cancel();
    deadlineTimer.cancel();

    var bytes = _rx.takeBytes();
    if (expected != null && bytes.length > expected && bytes[1] & 0x80 == 0) {
      bytes = Uint8List.sublistView(bytes, 0, expected);
    } else if (bytes.length >= 5 && bytes[1] & 0x80 != 0) {
      bytes = Uint8List.sublistView(bytes, 0, 5);
    }
    return Uint8List.fromList(bytes);
  }

  void _drop() {
    _sub = null;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await link.close();
    _drop();
  }
}
