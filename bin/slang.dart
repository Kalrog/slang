import 'package:slang/slang.dart';

void main(List<String> arguments) {
  // print('Hello world: ${slang.calculate()}!');
  final vm = SlangVm();
  // vm.compile("""thing = (4 + 4) * 6
  // return thing
  // """);
  // vm.compile('return "Hello, World!"');
  // vm.compile('''table = { 1 , 2 , 3 ,user:{ name: "Jonathan"} }
  // if(table.user.name == "Jonathan"){
  //   local name = "John"
  //   table.user.name = name
  // }else{
  //   local other = 1
  // }
  // return table.user.name
  // ''');
  vm.registerDartFunction('print', (vm, args) {
    print(args[0]);
    return null;
  });
  vm.compile('''
incrementer = func (n) {
  local v = 0
  return func () {
    v = v + n
    return v
  }
}
inc = incrementer(2)
print(inc())
print(inc())
print(inc())
print(inc())
''');
  // vm.debugPrintInstructions();
  vm.call(0, step: true);
  // print(vm.toString2(0));
}
