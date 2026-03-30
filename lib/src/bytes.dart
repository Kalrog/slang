import 'dart:convert';
import 'dart:typed_data';

class ByteWriter {
  List<int> _bytes = [];
  ByteWriter();
  void writeByte(int byte) {
    _bytes.add(byte);
  }

  void writeInt(int integer) {
    _bytes.add(integer & 0xff);
    _bytes.add((integer >> 8) & 0xff);
    _bytes.add((integer >> 16) & 0xff);
    _bytes.add((integer >> 24) & 0xff);
  }

  void writeDouble(double double) {
    final byteData = ByteData(8);
    byteData.setFloat64(0, double, Endian.little);
    for (var i = 0; i < 8; i++) {
      _bytes.add(byteData.getUint8(i));
    }
  }

  void writeBool(bool bool) {
    _bytes.add(bool ? 1 : 0);
  }

  void writeString(String string) {
    final encoded = utf8.encode(string);
    if (encoded.length > 255) {
      _bytes.add(255);
      writeInt(encoded.length);
    } else {
      _bytes.add(encoded.length);
    }
    _bytes.addAll(encoded);
  }

  void writeAll(Uint8List bytes) {
    _bytes.addAll(bytes);
  }

  Uint8List toBytes() {
    return Uint8List.fromList(_bytes);
  }
}

class ByteReader {
  final Uint8List _bytes;
  int _index = 0;
  ByteReader(this._bytes);

  int readByte() {
    return _bytes[_index++];
  }

  int readInt() {
    final value = _bytes[_index] |
        _bytes[_index + 1] << 8 |
        _bytes[_index + 2] << 16 |
        _bytes[_index + 3] << 24;
    _index += 4;
    return value;
  }

  double readDouble() {
    final byteData = ByteData(8);
    for (var i = 0; i < 8; i++) {
      byteData.setUint8(i, _bytes[_index + i]);
    }
    _index += 8;
    return byteData.getFloat64(0, Endian.little);
  }

  bool readBool() {
    return readByte() == 1;
  }

  String readString() {
    final lengthByte = readByte();
    final length = lengthByte == 255 ? readInt() : lengthByte;
    final string = utf8.decode(_bytes.sublist(_index, _index + length));
    _index += length;
    return string;
  }
}
