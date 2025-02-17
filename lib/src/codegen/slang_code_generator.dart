import 'package:slang/slang.dart';
import 'package:slang/src/codegen/function_assembler.dart';
import 'package:slang/src/vm/function_prototype.dart';

class SlangCodeGenerator extends AstNodeVisitor<void, Null> {
  late FunctionAssembler _assembler;

  FunctionPrototype generate(AstNode node) {
    _assembler = FunctionAssembler();
    visit(node);
    return _assembler.assemble();
  }

  @override
  void visit(AstNode node, [Null arg]) {
    super.visit(node, arg);
  }

  @override
  void visitIntLiteral(IntLiteral node, Null arg) {
    _assembler.emitLoadConstant(node.value);
  }

  @override
  void visitStringLiteral(StringLiteral node, Null arg) {
    _assembler.emitLoadConstant(node.value);
  }

  @override
  void visitBinOp(BinOp node, Null arg) {
    if (["and", "or"].contains(node.op)) {
      visitLogicalBinOp(node);
    } else {
      visitArithBinOp(node);
    }
  }

  void visitArithBinOp(BinOp node) {
    visit(node.left, null);
    visit(node.right, null);
    switch (node.op) {
      case '>':
        _assembler.emitBinOp('<=');
        _assembler.emitUnOp('not');
      case '>=':
        _assembler.emitBinOp('<');
        _assembler.emitUnOp('not');
      case '!=':
        _assembler.emitBinOp('==');
        _assembler.emitUnOp('not');
      default:
        _assembler.emitBinOp(node.op);
    }
  }

  void visitLogicalBinOp(BinOp node) {}

  @override
  void visitUnOp(UnOp node, Null arg) {
    visit(node.exp);
    _assembler.emitUnOp(node.op);
  }

  @override
  void visitAssignment(Assignment node, Null arg) {
    switch (node.left) {
      case Name(:final value):
        final localVar = _assembler.getLocalVar(value);
        visit(node.exp);
        _assembler.emitMove(localVar.register);
      case Index(:final target, :final key):
        visit(target);
        visit(key);
        visit(node.exp);
        _assembler.emitSetTable();
      default:
        throw ArgumentError('Invalid assignment target: ${node.left}');
    }
  }

  @override
  void visitReturnStatement(ReturnStatement node, Null arg) {
    visit(node.exp);
    _assembler.emitReturn();
  }

  @override
  void visitBlock(Block node, Null arg) {
    _assembler.enterScope();
    for (final statement in node.statements) {
      visit(statement);
    }
    if (node.finalStatement != null) {
      visit(node.finalStatement!);
    }
    _assembler.leaveScope();
  }

  @override
  void visitName(Name node, Null arg) {
    final localVar = _assembler.getLocalVar(node.value);
    _assembler.emitPush(localVar.register);
  }

  @override
  void visitField(Field node, Null arg) {
    _assembler.emitPush(-1);
    visit(node.key!);
    visit(node.value);
    _assembler.emitSetTable();
  }

  @override
  void visitTableLiteral(TableLiteral node, Null arg) {
    List<Field> arrayFields =
        node.fields.where((node) => node.key == null).toList();
    List<Field> mapFields =
        node.fields.where((node) => node.key != null).toList();
    _assembler.emitNewTable(arrayFields.length, mapFields.length);
    arrayFields = arrayFields.indexed
        .map((e) => Field(IntLiteral(e.$1), e.$2.value))
        .toList();
    for (var field in arrayFields) {
      visit(field);
    }
    for (var field in mapFields) {
      visit(field);
    }
  }

  @override
  void visitIndex(Index node, Null arg) {
    visit(node.target);
    visit(node.key);
    _assembler.emitGetTable();
  }

  @override
  void visitFalseLiteral(FalseLiteral node, Null arg) {
    _assembler.emitLoadBool(false);
  }

  @override
  void visitIfStatement(IfStatement node, Null arg) {
    visit(node.condition);
    _assembler.emitTest(true);
    int elseJump = _assembler.emitJump();
    visit(node.thenBranch);
    if (node.elseBranch != null) {
      int skipElseJump = _assembler.emitJump();
      _assembler.patchJump(elseJump);
      visit(node.elseBranch!);
      _assembler.patchJump(skipElseJump);
    } else {
      _assembler.patchJump(elseJump);
    }
  }

  @override
  void visitTrueLiteral(TrueLiteral node, Null arg) {
    _assembler.emitLoadBool(true);
  }
}
