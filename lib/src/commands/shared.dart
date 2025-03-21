import 'package:slang/slang.dart';

SlangVm cliSlangVm() {
  final vm = SlangVm.create(loadStdLib: true);
  return vm;
}
