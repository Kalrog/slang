class SlangTable {
  final Map<Object, Object?> _map;
  final List<Object?> _list;

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

  void add(Object value) {
    _list.add(value);
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
    if (key is int && key < _list.length && key >= 0) {
      return _list[key];
    } else {
      return _map[key];
    }
  }

  void operator []=(Object key, Object value) {
    if (key is int) {
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
}
