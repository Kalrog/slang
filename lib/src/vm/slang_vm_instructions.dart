import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class Instructions {
  static void loadConstant(SlangVm vm, int instruction) {
    vm.loadConstant(instruction.bx);
  }

  static void loadBool(SlangVm vm, int instruction) {
    bool value = instruction.b != 0;
    vm.push(value);
    if (instruction.c != 0) {
      vm.jump(1);
    }
  }

  static void add(SlangVm vm, int instruction) {
    vm.execBinOp(BinOpType.add);
  }

  static void sub(SlangVm vm, int instruction) {
    vm.execBinOp(BinOpType.sub);
  }

  static void mul(SlangVm vm, int instruction) {
    vm.execBinOp(BinOpType.mul);
  }

  static void div(SlangVm vm, int instruction) {
    vm.execBinOp(BinOpType.div);
  }

  static void mod(SlangVm vm, int instruction) {
    vm.execBinOp(BinOpType.mod);
  }

  static void neg(SlangVm vm, int instruction) {
    vm.execUnOp(UnOpType.neg);
  }

  static void not(SlangVm vm, int instruction) {
    vm.execUnOp(UnOpType.not);
  }

  static void lt(SlangVm vm, int instruction) {
    vm.execRelOp(RelOpType.lt);
  }

  static void leq(SlangVm vm, int instruction) {
    vm.execRelOp(RelOpType.leq);
  }

  static void eq(SlangVm vm, int instruction) {
    vm.execRelOp(RelOpType.eq);
  }

  static void move(SlangVm vm, int instruction) {
    vm.replace(instruction.sbx);
  }

  static void push(SlangVm vm, int instruction) {
    vm.pushValue(instruction.sbx);
  }

  static void returnOp(SlangVm vm, int instruction) {
    vm.returnOp(-1);
  }

  static void newTable(SlangVm vm, int instruction) {
    vm.newTable(instruction.b, instruction.c);
  }

  static void setTable(SlangVm vm, int instruction) {
    vm.setTable();
  }

  static void getTable(SlangVm vm, int instruction) {
    vm.getTable();
  }

  static void test(SlangVm vm, int instruction) {
    if (vm.toBool(-1) != (instruction.c != 0)) {
      vm.jump(1);
    }
    vm.pop();
  }

  static void jump(SlangVm vm, int instruction) {
    vm.jump(instruction.sbx);
  }

  static void pop(SlangVm vm, int instruction) {
    int keep = instruction.a;
    int pop = instruction.bx;
    vm.pop(keep, pop);
  }
}
