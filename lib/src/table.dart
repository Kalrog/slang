class SlangTable {
  final Map<Object, Object?> _map;
  final List<Object?> _list;
  SlangTable? metatable;

  SlangTable([int nArray = 0, int nHash = 0])
      : _map = {},
        _list = List.filled(nArray, null, growable: true);

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
}
