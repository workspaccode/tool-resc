import 'dart:async';
import 'dart:typed_data';

/// Called with every frame sent (tx) or received, for the traffic log.
typedef FrameLogger = void Function(bool tx, Uint8List frame);

/// A link to Modbus devices that sends one request at a time and returns
/// the response PDU. Implementations: TCP (MBAP) and serial RTU (CRC).
abstract class ModbusTransport {
  FrameLogger? onFrame;

  /// e.g. `TCP 192.168.1.10:502` or `RTU COM3 9600 8E1`.
  String get label;

  Future<void> open();

  /// Sends [pdu] to [unitId] and returns the response PDU (function code +
  /// data). Exception responses are returned as is; the caller decides.
  Future<Uint8List> request(int unitId, Uint8List pdu, {required Duration timeout});

  Future<void> close();

  /// Completes when the link drops (cable pulled, socket closed by peer).
  Future<void> get done;
}

/// Runs async work one at a time: Modbus is request/response, and most
/// devices and RS485 buses can't take overlapping requests.
class SerialQueue {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _last.then((_) => task());
    _last = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// Thrown when no answer arrives in time.
class ModbusTimeout implements Exception {
  const ModbusTimeout(this.after);

  final Duration after;

  @override
  String toString() => 'Timeout: no response in ${after.inMilliseconds} ms';
}
