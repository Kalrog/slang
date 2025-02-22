import 'dart:io';

import 'package:args/args.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/stdlib.dart';

void main(List<String> arguments) {
  // print('Hello world: ${slang.calculate()}!');
  final vm = SlangVm();
  SlangStdLib.register(vm);
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
//   vm.registerDartFunction('print', (vm, args) {
//     print(args[0]);
//     return null;
//   });
//   vm.compile('''
// local func counter (n) {
//   local v = 0
//   return {inc:func () {
//     v = v + n
//     return v
//   },dec: func(){
//     v = v - n
//     return v
//   }}
// }
// local tbl = counter(2)
// local inc = tbl.inc
// local dec = tbl.dec
// print(inc())
// print(inc())
// print(inc())
// print(dec())
// print(dec())
// print(inc())
// print(dec())
// ''');

//   vm.compile('''
//   print("Testing and / or short circuiting");
//   local a = func(){
//     print("a");
//     return true;
//   }
//   local b = func(){
//     print("b");
//     return false;
//   }
//   print("a() and b()");
//   print(a() and b());
//   print("a() or b()");
//   print(a() or b());
//   print("b() and a()");
//   print(b() and a());
//   print("b() or a()");
//   print(b() or a());
// ''');

//   vm.compile('''
// print("Testing for loop")
// print("normal use case")
// for(local i = 0; i <= 5; i = i + 1){
//   print(i)
// }
//
// print("no init use case")
// local i = 0
// for(i <= 5; i = i + 1){
//   print(i)
// }
//
//
// print("no update use case")
// for( local i = 0; i <= 5){
//   print(i)
//   i = i + 1
// }
//
// print("while style use case")
// local i = 0;
// for(i <= 5){
//   print(i)
//   i = i + 1
// }
//
// ''');
  // vm.compile('''
  //   local fore = "test"
  //   print(fore)
  //   ''');
  // vm.debugPrintInstructions();
  // vm.mode = ExecutionMode.step;
  // vm.call(0);
  // print(vm.toString2(0));

  ArgParser argParser = ArgParser();
  argParser.addFlag('debug', abbr: 'd', help: 'Debug mode', defaultsTo: false);
  argParser.addFlag('step', abbr: 's', help: 'Step mode', defaultsTo: false);

  ArgParser runParser = ArgParser();
  argParser.addCommand('run', runParser);

  var result = argParser.parse(arguments);
  if (result['debug']) {
    vm.mode = ExecutionMode.runDebug;
  }
  if (result['step']) {
    vm.mode = ExecutionMode.step;
  }

  if (result.command?.name == 'run') {
    final arguments = result.command?.rest;
    if (arguments != null && arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final source = file.readAsStringSync();
      vm.compile(source);
      vm.call(0);
    }
  }
}
