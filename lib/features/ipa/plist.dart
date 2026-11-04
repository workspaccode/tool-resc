import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// Reads a property list (Info.plist), XML or binary (`bplist00`, which is
/// what Xcode writes into built apps). Returns Dart values: Map, List,
/// String, int, double, bool, DateTime, Uint8List.
Object? parsePlist(Uint8List bytes) {
  if (bytes.length >= 8 && ascii.decode(bytes.sublist(0, 6), allowInvalid: true) == 'bplist') {
    return _BinaryPlist(bytes).read();
  }
  return _parseXml(utf8.decode(bytes, allowMalformed: true));
}

Object? _parseXml(String text) {
  final doc = XmlDocument.parse(text);
  final root = doc.rootElement;
  final top = root.name.local == 'plist' ? root.childElements.firstOrNull : root;
  return top == null ? null : _xmlValue(top);
}

Object? _xmlValue(XmlElement e) => switch (e.name.local) {
  'dict' => () {
    final out = <String, Object?>{};
    String? key;
    for (final child in e.childElements) {
      if (child.name.local == 'key') {
        key = child.innerText;
      } else if (key != null) {
        out[key] = _xmlValue(child);
        key = null;
      }
    }
    return out;
  }(),
  'array' => [for (final child in e.childElements) _xmlValue(child)],
  'string' => e.innerText,
  'integer' => int.tryParse(e.innerText.trim()),
  'real' => double.tryParse(e.innerText.trim()),
  'true' => true,
  'false' => false,
  'date' => DateTime.tryParse(e.innerText.trim()),
  'data' => base64.decode(e.innerText.replaceAll(RegExp(r'\s'), '')),
  _ => null,
};

/// Apple binary property list, version 00.
class _BinaryPlist {
  _BinaryPlist(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  late final int _offsetSize;
  late final int _refSize;
  late final int _count;
  late final int _tableOffset;

  /// Guards against reference cycles in a malformed file.
  int _depth = 0;

  Object? read() {
    if (bytes.length < 40) throw const FormatException('Property list is too short');
    final trailer = bytes.length - 32;
    _offsetSize = bytes[trailer + 6];
    _refSize = bytes[trailer + 7];
    _count = _uint(trailer + 8, 8);
    final top = _uint(trailer + 16, 8);
    _tableOffset = _uint(trailer + 24, 8);
    if (_offsetSize < 1 || _offsetSize > 8 || _refSize < 1 || _refSize > 8 || top >= _count) {
      throw const FormatException('Property list trailer is invalid');
    }
    return _object(top);
  }

  int _uint(int at, int size) {
    if (at < 0 || at + size > bytes.length) throw const FormatException('Property list is truncated');
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | bytes[at + i];
    }
    return v;
  }

  int _offsetOf(int ref) {
    if (ref >= _count) throw const FormatException('Property list reference is out of range');
    return _uint(_tableOffset + ref * _offsetSize, _offsetSize);
  }

  /// Length stored in a marker's low nibble, or in a following int when 0xF.
  (int length, int start) _length(int at) {
    final info = bytes[at] & 0x0F;
    if (info != 0x0F) return (info, at + 1);
    final size = 1 << (bytes[at + 1] & 0x0F);
    return (_uint(at + 2, size), at + 2 + size);
  }

  Object? _object(int ref) {
    if (++_depth > 512) throw const FormatException('Property list is nested too deeply');
    try {
      return _decode(_offsetOf(ref));
    } finally {
      _depth--;
    }
  }

  Object? _decode(int at) {
    final marker = bytes[at];
    final type = marker >> 4;
    final info = marker & 0x0F;
    switch (type) {
      case 0x0:
        return switch (info) {
          0x8 => false,
          0x9 => true,
          _ => null,
        };
      case 0x1:
        final size = 1 << info;
        if (size == 8) return data.getInt64(at + 1);
        return _uint(at + 1, size);
      case 0x2:
        return info == 2 ? data.getFloat32(at + 1) : data.getFloat64(at + 1);
      case 0x3:
        // Seconds since 2001-01-01 UTC.
        final seconds = data.getFloat64(at + 1);
        return DateTime.utc(2001).add(Duration(microseconds: (seconds * 1e6).round()));
      case 0x4:
        final (n, start) = _length(at);
        return Uint8List.fromList(bytes.sublist(start, start + n));
      case 0x5:
        final (n, start) = _length(at);
        return latin1.decode(bytes.sublist(start, start + n));
      case 0x6:
        final (n, start) = _length(at);
        final units = [for (var i = 0; i < n; i++) data.getUint16(start + i * 2)];
        return String.fromCharCodes(units);
      case 0x8:
        return _uint(at + 1, info + 1);
      case 0xA:
      case 0xC:
        final (n, start) = _length(at);
        return [for (var i = 0; i < n; i++) _object(_uint(start + i * _refSize, _refSize))];
      case 0xD:
        final (n, start) = _length(at);
        final out = <String, Object?>{};
        for (var i = 0; i < n; i++) {
          final key = _object(_uint(start + i * _refSize, _refSize));
          final value = _object(_uint(start + (n + i) * _refSize, _refSize));
          out['$key'] = value;
        }
        return out;
      default:
        throw FormatException('Unknown property list object type 0x${marker.toRadixString(16)}');
    }
  }
}
