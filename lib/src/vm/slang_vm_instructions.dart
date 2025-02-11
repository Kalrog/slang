import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class Instructions {
  static void loadConstant(SlangVm vm, int instruction) {
    vm.loadConstant(instruction.bx);
    vm.replace(instruction.a);
  }

  static void add(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.execBinOp(BinOpType.add);
    vm.replace(instruction.a);
  }

  static void sub(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.execBinOp(BinOpType.sub);
    vm.replace(instruction.a);
  }

  static void mul(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.execBinOp(BinOpType.mul);
    vm.replace(instruction.a);
  }

  static void div(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.execBinOp(BinOpType.div);
    vm.replace(instruction.a);
  }

  static void mod(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.execBinOp(BinOpType.mod);
    vm.replace(instruction.a);
  }

  static void neg(SlangVm vm, int instruction) {
    vm.loadRegisterOrConstant(instruction.b);
    vm.execUnOp(UnOpType.neg);
    vm.replace(instruction.a);
  }

  static void move(SlangVm vm, int instruction) {
    vm.pushValue(instruction.b);
    vm.replace(instruction.a);
  }

  static void returnOp(SlangVm vm, int instruction) {
    vm.returnOp(instruction.ax);
  }

  static void newTable(SlangVm vm, int instruction) {
    vm.newTable(instruction.b, instruction.c);
    vm.replace(instruction.a);
  }

  static void setTable(SlangVm vm, int instruction) {
    vm.pushValue(instruction.a);
    vm.loadRegisterOrConstant(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.setTable();
    vm.pop();
  }

  static void getTable(SlangVm vm, int instruction) {
    vm.pushValue(instruction.b);
    vm.loadRegisterOrConstant(instruction.c);
    vm.getTable();
    vm.replace(instruction.a);
  }
}
