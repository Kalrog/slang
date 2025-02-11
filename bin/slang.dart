import 'package:slang/slang.dart';

void main(List<String> arguments) {
  // print('Hello world: ${slang.calculate()}!');
  final vm = SlangVm();
  vm.compile("""thing = (4 + 4) * 6
  return thing
  """);
  // vm.compile('return "Hello, World!"');
  vm.call();
  print(vm.takeInt(0));
}
