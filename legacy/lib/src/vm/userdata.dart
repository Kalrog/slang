import 'package:slang/src/table.dart';

/// Userdata allows any Dart object to be stored in the Slang VM.
class Userdata<T extends Object> {
  final List<T> _value;

  /// Metatable of the Userdata.
  /// Just like a Slang Tables, Userdata can have a metatable.
  /// This metatable can define special behavior for the Userdata.
  /// Like defining how to index the Userdata,or how to add indices to the Userdata.
  SlangTable? metatable = SlangTable();

  /// Creates a new Userdata.
  Userdata(T value) : _value = [value];

  /// Returns the value of the Userdata.
  T get value => _value.first;

  /// Sets the value of the Userdata.
  set value(T value) {
    _value[0] = value;
  }

  @override
  String toString() {
    return value.toString();
  }
}
