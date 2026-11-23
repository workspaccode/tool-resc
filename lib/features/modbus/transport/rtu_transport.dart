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
  DateTime _lastByteAt = DateTime.now();

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
        _lastByteAt = DateTime.now();
        // Keep only enough bytes for the largest possible RTU frame.
        if (_rx.length > 300) {
          final all = _rx.takeBytes();
          _rx.add(Uint8List.sublistView(all, all.length - 300));
        }
        _onBytes?.call();
      },
      onError: (_) => _drop(),
      onDone: _drop,
    );
  }

  @override
  Future<Uint8List> request(
    int unitId,
    Uint8List pdu, {
    required Duration timeout,
  }) => _queue.run(() async {
    if (_sub == null) throw StateError('Serial port is not open');

    // The inverter may stream unsolicited frames. Let the line go quiet
    // before transmitting, then drop whatever arrived earlier.
    await _waitForIdle();
    _rx.clear();

    final frame = rtuFrame(unitId, pdu);
    onFrame?.call(true, frame);
    await link.write(frame);

    final deadline = DateTime.now().add(timeout);
    final answer = await _collect(unitId, pdu[0], deadline, unitId == 0);
    if (unitId == 0) return pdu; // broadcast: nobody answers; treat as accepted
    if (answer.isEmpty) throw ModbusTimeout(timeout);
    onFrame?.call(false, answer);
    return rtuPdu(answer, unitId);
  });

  /// Waits until the line has been silent for [silence], up to 500 ms.
  Future<void> _waitForIdle() async {
    final end = DateTime.now().add(const Duration(milliseconds: 500));
    while (DateTime.now().isBefore(end)) {
      final quietFor = DateTime.now().difference(_lastByteAt);
      if (quietFor >= silence) return;
      final remaining = silence - quietFor;
      await Future<void>.delayed(
        remaining > const Duration(milliseconds: 10)
            ? const Duration(milliseconds: 10)
            : remaining,
      );
    }
  }

  /// Waits for a complete, CRC-valid frame matching the request. Broadcast
  /// (unit 0) has no answer.
  Future<Uint8List> _collect(
    int unitId,
    int fc,
    DateTime deadline,
    bool broadcast,
  ) async {
    if (broadcast) {
      await Future<void>.delayed(silence * 2);
      return Uint8List(0);
    }

    Timer? deadlineTimer;
    final done = Completer<void>();
    Uint8List? found;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    bool scan() {
      final frame = findMatchingRtuFrame(_rx.toBytes(), unitId, fc);
      if (frame == null) return false;
      found = frame;
      return true;
    }

    _onBytes = () {
      if (scan()) finish();
    };

    final left = deadline.difference(DateTime.now());
    deadlineTimer = Timer(left.isNegative ? Duration.zero : left, finish);
    if (_rx.length > 0 && scan()) finish();

    await done.future;
    _onBytes = null;
    deadlineTimer.cancel();

    if (found != null) return found!;

    final raw = _rx.takeBytes();
    if (raw.isNotEmpty) {
      onFrame?.call(false, raw);
      throw FormatException(
        'No matching Modbus response (${raw.length} bytes). Check baud rate, parity and unit ID.',
      );
    }
    return raw;
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
