import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/modbus_codec.dart';
import 'modbus_transport.dart';

/// Modbus TCP straight from the app (no WebSocket bridge needed).
class TcpTransport extends ModbusTransport {
  TcpTransport({required this.host, required this.port, this.connectTimeout = const Duration(seconds: 5)});

  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;
  final _queue = SerialQueue();
  final _pending = <int, Completer<Uint8List>>{};
  final _rx = BytesBuilder(copy: false);
  final _done = Completer<void>();
  var _tid = 0;

  @override
  String get label => 'TCP $host:$port';

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> open() async {
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    socket.listen(_onData, onError: (_) => _drop(), onDone: _drop, cancelOnError: true);
  }

  @override
  Future<Uint8List> request(int unitId, Uint8List pdu, {required Duration timeout}) => _queue.run(() async {
    final socket = _socket;
    if (socket == null) throw const SocketException('Not connected');
    _tid = _tid % 0xFFFF + 1;
    final tid = _tid;
    final completer = Completer<Uint8List>();
    _pending[tid] = completer;
    final frame = tcpFrame(tid, unitId, pdu);
    onFrame?.call(true, frame);
    socket.add(frame);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => throw ModbusTimeout(timeout));
    } finally {
      _pending.remove(tid);
    }
  });

  void _onData(Uint8List data) {
    _rx.add(data);
    var buf = _rx.takeBytes();
    // Frames may arrive split or several at once.
    while (buf.length >= 7) {
      final total = 6 + ((buf[4] << 8) | buf[5]);
      if (buf.length < total) break;
      final frame = Uint8List.sublistView(buf, 0, total);
      onFrame?.call(false, Uint8List.fromList(frame));
      final tid = (frame[0] << 8) | frame[1];
      _pending[tid]?.complete(Uint8List.fromList(frame.sublist(7)));
      buf = Uint8List.sublistView(buf, total);
    }
    if (buf.isNotEmpty) _rx.add(Uint8List.fromList(buf));
  }

  void _drop() {
    _socket = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const SocketException('Connection closed by the device'));
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
    socket?.destroy();
    _drop();
  }
}
