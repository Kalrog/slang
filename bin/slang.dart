import 'package:slang/slang.dart';

void main(List<String> arguments) {
  // print('Hello world: ${slang.calculate()}!');
  final vm = SlangVm();
  // vm.compile("""thing = (4 + 4) * 6
  // return thing
  // """);
  // vm.compile('return "Hello, World!"');
  vm.compile('''table = { 1 , 2 , 3 ,user:{ name: "Jonathan"} }
  if(table.user.name != "Jonathan"){
    name = "John"
    table.user.name = name 
  }else{
    other = 1
  }
  return table.user.name
  ''');
  // vm.debugPrintInstructions();
  vm.call(step: true);
  print(vm.toString2(0));
}
