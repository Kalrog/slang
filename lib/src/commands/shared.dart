import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/stdlib/std_lib.dart';
import 'package:slang/src/stdlib/test_lib.dart';
import 'package:slang/src/stdlib/vm_lib.dart';

SlangVm cliSlangVm() {
  final vm = SlangVm();
  SlangPackageLib.register(vm);
  SlangVmLib.register(vm);
  SlangStdLib.register(vm);
  SlangTestLib.register(vm);
  return vm;
}
