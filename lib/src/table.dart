extension ItterableToSlangTable<T> on Iterable<T> {
  SlangTable toSlangTable() {
    return SlangTable.fromList(toList());
  }
}

class SlangTable {
  final Map<Object, Object?> _map;
  final List<Object?> _list;

  /// Metatable of the SlangTable.
  /// The metatable can define a number of special behaviors for the table, by
  /// assigning values to specific entries in the metatable.
  /// The Slang VM uses the following keys in the metatable:
  /// __index: a function(func(table,key) -> value ) or table to be called/used
  /// when a non-existent key is accessed on the table.
  /// __newindex: a function(func(table,key,value) ) or table to be called/used
  /// when a non-existent key is assigned on the table.
  /// __type: a string that represents the type of the table.
  SlangTable? metatable;

  SlangTable([int nArray = 0, int nHash = 0])
      : _map = {},
        _list = List.filled(nArray, null, growable: true);

  SlangTable.fromMap(Map<Object, Object?> map)
      : _map = Map.from(map),
        _list = [] {
    _fixList();
  }

  SlangTable.fromList(List<Object?> list)
      : _map = {},
        _list = List.from(list);

  SlangTable.fromParts(List<Object?> list, Map<Object, Object?> map)
      : _map = Map.from(map),
        _list = List.from(list) {
    _fixList();
  }

  Object? remove(Object key) {
    if (key is int && key < _list.length && key >= 0) {
      return _list.removeAt(key);
    } else {
      return _map.remove(key);
    }
  }

  void add(Object? value) {
    _list.add(value);
    _fixList();
  }

  void addAll(SlangTable table) {
    _list.addAll(table._list);
    _map.addAll(table._map);
    _fixList();
  }

  void _fixList() {
    for (var i = _list.length; true; i++) {
      if (_map.containsKey(i)) {
        _list.add(_map.remove(i)!);
      } else {
        break;
      }
    }
  }

  Object? operator [](Object key) {
    if (key is String && key == "meta") {
      return metatable;
    } else if (key is int && key < _list.length && key >= 0) {
      return _list[key];
    } else {
      return _map[key];
    }
  }

  void operator []=(Object key, Object? value) {
    if (value == null) {
      remove(key);
      return;
    }
    if (key is String && key == "meta") {
      metatable = value as SlangTable?;
    } else if (key is int) {
      if (key < _list.length && key >= 0) {
        _list[key] = value;
      } else if (key == _list.length) {
        add(value);
      } else {
        _map[key] = value;
      }
    } else {
      _map[key] = value;
    }
  }

  int get length => _list.length + _map.length;

  @override
  String toString() {
    StringBuffer sb = StringBuffer();
    if (metatable?['__type'] is String) {
      sb.write("'${metatable!['__type']}");
    }

    sb.write('{');
    for (var i = 0; i < _list.length; i++) {
      sb.write('$i: ${_list[i]}, ');
    }
    for (var key in _map.keys) {
      sb.write('$key: ${_map[key]}, ');
    }
    sb.write('}');
    return sb.toString();
  }

  Map toMap() {
    final map = Map<Object, Object?>.from(_map);
    for (var i = 0; i < _list.length; i++) {
      map[i] = _list[i];
    }
    return map;
  }

  List toList() {
    return List.from(_list);
  }

  List<Object> get keys {
    final keys = <Object>[];
    for (var i = 0; i < _list.length; i++) {
      keys.add(i);
    }
    keys.addAll(_map.keys);
    return keys;
  }

  List<Object?> get values => [..._list, ..._map.values];

  /// Removel all objects from this table.
  void clear() {
    _list.clear();
    _map.clear();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SlangTable) return false;
    if (other.length != length) return false;
    if (other._list.length != _list.length) return false;
    if (other._map.length != _map.length) return false;
    for (int i = 0; i < _list.length; i++) {
      if (other._list[i] != _list[i]) return false;
    }
    for (Object key in _map.keys) {
      if (other._map[key] != _map[key]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(_list, _map, metatable);

  void addAllList(List list) {
    _list.addAll(list);
    _fixList();
  }
}
