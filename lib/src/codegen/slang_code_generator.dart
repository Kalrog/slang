import 'package:slang/slang.dart';
import 'package:slang/src/codegen/function_assembler.dart';
import 'package:slang/src/vm/function_prototype.dart';

class SlangCodeGenerator extends AstNodeVisitor<void, int> {
  late FunctionAssembler _assembler;

  FunctionPrototype generate(AstNode node) {
    _assembler = FunctionAssembler();
    final outputPosition = _assembler.allocateRegister();
    node.accept(this, outputPosition);
    return _assembler.assemble();
  }

  @override
  void visitIntLiteral(IntLiteral node, int a) {
    _assembler.emitLoadConstant(a, node.value);
  }

  @override
  void visitStringLiteral(StringLiteral node, int a) {
    _assembler.emitLoadConstant(a, node.value);
  }

  @override
  void visitBinOp(BinOp node, int a) {
    final b = _prepareOperatorArgument(node.left);
    final c = _prepareOperatorArgument(node.right);
    _assembler.emitBinOp(a, b, c, node.op);
  }

  int _prepareOperatorArgument(Exp exp) {
    if (exp case IntLiteral(value: dynamic value) || StringLiteral(value: dynamic value)) {
      final constIndex = _assembler.indexOfConstant(value);
      final regOrConst = constIndex | 0x100;
      return regOrConst;
    } else if (exp case Name(value: dynamic value)) {
      final localVar = _assembler.getLocalVar(value);
      return localVar.register;
    }
    final reg = _assembler.allocateRegister();
    exp.accept(this, reg);
    return reg;
  }

  @override
  void visitUnOp(UnOp node, int a) {
    final b = _prepareOperatorArgument(node.exp);
    _assembler.emitUnOp(a, b, node.op);
  }

  @override
  void assignment(Assignment statement, int arg) {
    final localVar = _assembler.getLocalVar(statement.name.value);
    statement.exp.accept(this, localVar.register);
  }

  @override
  void returnStatement(ReturnStatement statement, int arg) {
    final returnVal = _assembler.allocateRegister();
    statement.exp.accept(this, returnVal);
    _assembler.emitReturn(returnVal);
  }

  @override
  void visitBlock(Block block, int arg) {
    for (final statement in block.statements) {
      statement.accept(this, arg);
    }
    block.finalStatement?.accept(this, arg);
  }

  @override
  void visitName(Name node, int arg) {
    final localVar = _assembler.getLocalVar(node.value);
    _assembler.emitMove(arg, localVar.register);
  }

  void insertField(Field node, int tableIndex) {
    // TODO: implement visitField
    var key = node.key;
    var value = node.value;
  }

  @override
  void visitTableLiteral(TableLiteral node, int a) {
    List<Field> arrayFields = node.fields.where((node) => node.key == null).toList();
    List<Field> mapFields = node.fields.where((node) => node.key != null).toList();
    _assembler.emitNewTable(a, arrayFields.length, mapFields.length);
    for (var (i, field) in arrayFields.indexed) {
      field.accept(this, a);
    }
    for (var field in mapFields) {
      field.accept(this, a);
    }
  }
}
