import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Minimal zip writer for IPAs.
///
/// `package:archive` marks entries as made on MS-DOS and drops symlinks, so
/// unzip tools and iOS ignore the Unix permission bits: the app's executable
/// loses its +x bit and the IPA won't install. This writer records entries
/// as made on Unix with the full mode (file type + permissions), the way
/// Xcode and `ditto` do.
class IpaZipWriter {
  IpaZipWriter(String path) : _out = File(path).openSync(mode: FileMode.write);

  final RandomAccessFile _out;
  final _central = BytesBuilder(copy: false);
  int _offset = 0;
  int _entries = 0;

  static const _sIfReg = 0x8000;
  static const _sIfDir = 0x4000;
  static const _sIfLnk = 0xA000;

  /// Without zip64, sizes and offsets must stay below 4 GB and the entry
  /// count below 65 535. Flutter apps are far smaller.
  static const _max32 = 0xFFFFFFFF;
  static const _maxEntries = 0xFFFF;

  void addDirectory(String name, {int permissions = 0x1ED, DateTime? modified}) {
    final n = name.endsWith('/') ? name : '$name/';
    _add(n, Uint8List(0), mode: _sIfDir | (permissions & 0xFFF), modified: modified, compress: false, isDir: true);
  }

  void addFile(String name, Uint8List bytes, {int permissions = 0x1A4, DateTime? modified, bool compress = true}) {
    _add(name, bytes, mode: _sIfReg | (permissions & 0xFFF), modified: modified, compress: compress);
  }

  /// Stored as the link target text, as Info-ZIP does.
  void addSymlink(String name, String target, {DateTime? modified}) {
    _add(name, utf8.encode(target), mode: _sIfLnk | 0x1ED, modified: modified, compress: false);
  }

  void _add(
    String name,
    Uint8List bytes, {
    required int mode,
    required bool compress,
    DateTime? modified,
    bool isDir = false,
  }) {
    if (_entries >= _maxEntries) throw const FileSystemException('The app has too many files for an IPA (over 65 535)');
    final nameBytes = utf8.encode(name.replaceAll('\\', '/'));
    final crc = bytes.isEmpty ? 0 : getCrc32(bytes);

    var method = 0;
    var payload = bytes;
    if (compress && bytes.length > 64) {
      final deflated = ZLibCodec(raw: true, level: 6).encode(bytes);
      if (deflated.length < bytes.length) {
        method = 8;
        payload = deflated is Uint8List ? deflated : Uint8List.fromList(deflated);
      }
    }
    if (bytes.length > _max32 || _offset + payload.length > _max32) {
      throw const FileSystemException('The IPA would be larger than 4 GB');
    }

    final (time, date) = _dosDateTime(modified ?? DateTime.now());
    const versionNeeded = 20;
    const flags = 0x0800; // UTF-8 names.

    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, versionNeeded, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, time, Endian.little)
      ..setUint16(12, date, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, bytes.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);

    final headerOffset = _offset;
    _write(local.buffer.asUint8List());
    _write(nameBytes);
    _write(payload);

    // External attributes: Unix mode in the high 16 bits, MS-DOS directory
    // flag in the low bits for readers that only look at those.
    final external = (mode << 16) | (isDir ? 0x10 : 0);
    final central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, (3 << 8) | 30, Endian.little) // Made by Unix, zip 3.0.
      ..setUint16(6, versionNeeded, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint16(12, time, Endian.little)
      ..setUint16(14, date, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, bytes.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, 0, Endian.little) // Extra length.
      ..setUint16(32, 0, Endian.little) // Comment length.
      ..setUint16(34, 0, Endian.little) // Disk number.
      ..setUint16(36, 0, Endian.little) // Internal attributes.
      ..setUint32(38, external, Endian.little)
      ..setUint32(42, headerOffset, Endian.little);
    _central
      ..add(central.buffer.asUint8List())
      ..add(nameBytes);
    _entries++;
  }

  /// Writes the central directory and closes the file.
  void close() {
    final centralOffset = _offset;
    final centralBytes = _central.takeBytes();
    if (centralOffset + centralBytes.length > _max32) {
      throw const FileSystemException('The IPA would be larger than 4 GB');
    }
    _write(centralBytes);
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, _entries, Endian.little)
      ..setUint16(10, _entries, Endian.little)
      ..setUint32(12, centralBytes.length, Endian.little)
      ..setUint32(16, centralOffset, Endian.little)
      ..setUint16(20, 0, Endian.little);
    _write(end.buffer.asUint8List());
    _out.closeSync();
  }

  /// Closes the file without finishing it (after an error).
  void abort() {
    try {
      _out.closeSync();
    } catch (_) {}
  }

  void _write(List<int> bytes) {
    _out.writeFromSync(bytes);
    _offset += bytes.length;
  }

  static (int time, int date) _dosDateTime(DateTime t) {
    if (t.year < 1980) t = DateTime(1980);
    final time = (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
    final date = ((t.year - 1980) << 9) | (t.month << 5) | t.day;
    return (time, date);
  }
}
