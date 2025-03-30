import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/userdata.dart';

Object? toSlang(Object? value) {
  switch (value) {
    case int() ||
          double() ||
          String() ||
          bool() ||
          Null() ||
          Closure() ||
          SlangVmImpl() ||
          Userdata() ||
          SlangTable():
      return value;
    case List list:
      return SlangTable.fromList(list.map(toSlang).toList());
    case Map map:
      return SlangTable.fromMap(map.map((key, value) => MapEntry(key, toSlang(value))));
    case DartFunction function:
      return Closure.dart(function);
    default:
      return Userdata(value);
  }
}
